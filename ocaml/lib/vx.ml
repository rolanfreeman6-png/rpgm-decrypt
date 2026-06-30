(* VX `.rgssad` v2 / `.rgss2a`, thin wrapper over Rgssad_core
   (version 0x02, size=0 && name_len=0 sentinel). *)

type entry = Rgssad_core.entry
type parse_error = Rgssad_core.parse_error

let parse (buf : bytes) : (entry list * int, parse_error) result =
  Rgssad_core.parse 0x02 Rgssad_core.SizeAndNameZero buf

let parse_file (path : string) : (entry list * int, parse_error) result =
  parse (Io.read_file path)

let read_entry = Rgssad_core.read_entry
