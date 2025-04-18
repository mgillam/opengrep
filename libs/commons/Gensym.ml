(* Brandon Wu
 *
 * Copyright (C) 2023 r2c
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public License
 * version 2.1 as published by the Free Software Foundation, with the
 * special exception on linking described in file license.txt.
 *
 * This library is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the file
 * license.txt for more details.
 *)

(*****************************************************************************)
(* Prelude *)
(*****************************************************************************)

(*****************************************************************************)
(* Main functor *)
(*****************************************************************************)

(* OCaml has generative functors.
   This means that abstract types minted from different applications of the same
   functor are _always_ different, even if they are constructed in the exact
   same way.
   So different instances of the module `MkId` will have distinct types.
   This helps us not conflate types when we need a new kind of unique identifier type,
   and avoid boilerplate code with refs and counters.
*)
module MkId () : sig
  type t [@@deriving show, eq, ord, hash, sexp]

  val mk : unit -> t
  val to_int : t -> int
  val unsafe_default : t
  val is_unsafe_default : t -> bool
  val unsafe_reset_counter : unit -> unit

  type partition = A | B

  val set_partition : partition -> unit
end = struct
  open Ppx_hash_lib.Std.Hash.Builtin
  open Sexplib.Std

  type t = int [@@deriving show, eq, hash, sexp]
  type partition = A | B

  (* XXX: [partition] and [set_partition] do not seem used anywhere. *)
  let partition = Atomic.make A
  let set_partition p = Atomic.set partition p
  let counter_a = Atomic.make 0

  (* Why not just type t [@@deriving ord]?
   *
   * For some reason, ppx derives a function that allocates a closure
   * unnecessarily, causing IL.compare_name to be responsible for
   * ~7% of all allocations throughout a semgrep run!
   *
   * See: https://github.com/semgrep/semgrep-proprietary/pull/2266
   *)
  let compare = Int.compare

  (* We could use min_int and increment, but small negative numbers are
   * represented more compactly both in string-based serialization formats and
   * in OCaml's binary marshalling format. So, start with -2 (-1 is the unsafe
   * default) and move downward. *)
  let counter_b = Atomic.make (-2)

  let mk () =
    match Atomic.get partition with
    | A ->
        (Atomic.fetch_and_add counter_a 1) + 1
    | B ->
        (Atomic.fetch_and_add counter_b (-1)) - 1

  let to_int = Fun.id
  let unsafe_default = -1
  let is_unsafe_default id = Int.equal id unsafe_default

  let unsafe_reset_counter () =
    ignore (failwith "should not be used in OCaml 5 with domains");
    Atomic.set counter_a 0;
    Atomic.set counter_b (-2)
end
