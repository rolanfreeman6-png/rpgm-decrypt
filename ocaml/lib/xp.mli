(** RPG Maker XP [.rgssad] (version 0x01) — thin wrapper over {!Rgssad_core}
    with the [NameLenZero] sentinel. *)

type entry = Rgssad_core.entry
type parse_error = Rgssad_core.parse_error

val parse : bytes -> (entry list * int, parse_error) result
(** Parse an XP [.rgssad] buffer (version 0x01, [NameLenZero] sentinel). *)

val parse_file : string -> (entry list * int, parse_error) result
(** [parse_file path] reads [path] and parses it. *)

val read_entry : bytes -> entry -> bytes
(** See {!Rgssad_core.read_entry}. *)
