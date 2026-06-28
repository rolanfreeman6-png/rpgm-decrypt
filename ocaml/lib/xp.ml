(* Port of Format.Xp.fs — XP `.rgssad` v1, thin wrapper over Rgssad_core
   (version 0x01, name_len=0 sentinel). Entry/error types are Rgssad_core's. *)

type entry = Rgssad_core.entry
type parse_error = Rgssad_core.parse_error

let magic_key = Rgssad_core.magic_key
let xor_decode_name = Rgssad_core.xor_decode_name

let parse (buf : bytes) : (entry list * int, parse_error) result =
  Rgssad_core.parse 0x01 Rgssad_core.NameLenZero buf

let parse_file (path : string) : (entry list * int, parse_error) result =
  parse (Io.read_file path)

let read_entry = Rgssad_core.read_entry
