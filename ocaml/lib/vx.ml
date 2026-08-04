(* RPG Maker VX `.rgss2a` — RGSSAD v1 (byte-identical to XP's `.rgssad`;
   version byte is 0x01, NOT 0x02 — there is no RGSSAD v2). Thin wrapper over
   Rgssad_core. *)

type entry = Rgssad_core.entry
type parse_error = Rgssad_core.parse_error

let parse (buf : bytes) : (entry list * int, parse_error) result =
  Rgssad_core.parse buf

let parse_file (path : string) : (entry list * int, parse_error) result =
  parse (Io.read_file path)

let read_entry = Rgssad_core.read_entry
let decrypt_data = Rgssad_core.decrypt_data
