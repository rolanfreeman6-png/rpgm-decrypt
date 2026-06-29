(** RPG Maker VX [.rgssad] v2 / [.rgss2a] (version 0x02) — thin wrapper over
    {!Rgssad_core} with the [SizeAndNameZero] sentinel. *)

type entry = Rgssad_core.entry
type parse_error = Rgssad_core.parse_error

val parse : bytes -> (entry list * int, parse_error) result
(** Parse a VX [.rgssad]/[.rgss2a] buffer (version 0x02, [SizeAndNameZero]
    sentinel). *)

val parse_file : string -> (entry list * int, parse_error) result
(** [parse_file path] reads [path] and parses it. *)

val read_entry : bytes -> entry -> bytes
(** See {!Rgssad_core.read_entry}. *)
