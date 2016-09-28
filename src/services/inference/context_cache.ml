(**
 * Copyright (c) 2013-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the "flow" directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 *
 *)

open Utils_js

(****************** shared context heap *********************)

(* map from file names to contexts *)
(* NOTE: Entries are cached for performance, since contexts are read a lot more
   than they are written. But this means that proper care must be taken when
   reading contexts: in particular, context graphs have mutable bounds, so they
   must be copied, otherwise bad things will happen. (The cost of copying
   context graphs is presumably a lot less than deserializing contexts, so the
   optimization makes sense. *)
module ContextHeap = SharedMem.WithCache (Loc.FilenameKey) (struct
  type t = Context.t
  let prefix = Prefix.make()
  let description = "Context"
end)

let add_context = Expensive.wrap ContextHeap.add
let find_unsafe_context = Expensive.wrap ContextHeap.find_unsafe

module SigContextHeap = SharedMem.WithCache (Loc.FilenameKey) (struct
  type t = Context.t
  let prefix = Prefix.make()
  let description = "SigContext"
end)

let add_sig_context = Expensive.wrap SigContextHeap.add
let find_unsafe_sig_context = Expensive.wrap SigContextHeap.find_unsafe

let add ~audit cx =
  let cx_file = Context.file cx in
  add_context ~audit cx_file cx

let add_sig ~audit cx =
  let cx_file = Context.file cx in
  add_sig_context ~audit cx_file cx

let remove_batch cxs =
  ContextHeap.remove_batch cxs

let remove_sig_batch cxs =
  SigContextHeap.remove_batch cxs

(* We already cache contexts in the shared memory for performance, but context
   graphs need to be copied because they have mutable bounds. We maintain an
   additional cache of local copies. Mutating bounds in local copies of context
   graphs is not only OK, but we rely on it during merging, so it is both safe
   and necessary to cache the local copies. As a side effect, this probably
   helps performance too by avoiding redundant copying. *)
class context_cache = object(self)
  val cached_infer_contexts = Hashtbl.create 0

  (* find a context in the cache *)
  method find file =
    try Some (Hashtbl.find cached_infer_contexts file)
    with _ -> None

  (* read a context from shared memory, copy its graph, and cache the context *)
  method read ~audit file =
    let orig_cx =
      try find_unsafe_context ~audit file
      with Not_found ->
        raise (Key_not_found ("ContextHeap", (string_of_filename file)))
    in
    let cx = Context.copy_of_context orig_cx in
    Hashtbl.add cached_infer_contexts file cx;
    cx

  method read_safe ~audit file =
    try Some (self#read ~audit file)
    with Key_not_found _ -> None
end

(* Similar to above, but for "signature contexts." The only differences are that
   the underlying heap is SigContextHeap instead of ContextHeap, and that `read`
   returns both the original and the copied version of a context. *)
class sig_context_cache = object(self)
  val cached_merge_contexts = Hashtbl.create 0

  (* find a context in the cache *)
  method find file =
    try Some (Hashtbl.find cached_merge_contexts file)
    with _ -> None

  (* read a context from shared memory, copy its graph, and cache the context *)
  method read ~audit file =
    let orig_cx =
      try find_unsafe_sig_context ~audit file
      with Not_found ->
        raise (Key_not_found ("SigContextHeap", (string_of_filename file)))
    in
    let cx = Context.copy_of_context orig_cx in
    Hashtbl.add cached_merge_contexts file cx;
    orig_cx, cx

  method read_safe ~audit file =
    try Some (self#read ~audit file)
    with Key_not_found _ -> None
end
