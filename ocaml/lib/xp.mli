(** RPG Maker XP [.rgssad] (RGSSAD v1) — thin wrapper over {!Rgssad_core}. *)

type entry = Rgssad_core.entry
type parse_error = Rgssad_core.parse_error

val parse : bytes -> (entry list * int, parse_error) result
(** Parse an XP [.rgssad] buffer (RGSSAD v1, version byte 0x01). *)

val parse_file : string -> (entry list * int, parse_error) result
(** [parse_file path] reads [path] and parses it. *)

val read_entry : bytes -> entry -> bytes
(** See {!Rgssad_core.read_entry}. *)

val decrypt_data : entry -> bytes -> bytes
(** See {!Rgssad_core.decrypt_data}. *)
