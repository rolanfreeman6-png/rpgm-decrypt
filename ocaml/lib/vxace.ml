(* RGSS3 (`.rgss3a`, version 0x03).
   Master seed at byte 8 -> masterKey = seed*9+3; every entry field is XOR'd
   with masterKey; per-entry payload uses a rotating key (in Vxace_key). *)

type entry = { index : int; name : string; offset : int; size : int; key : int }
type parse_error = ShortHeader | BadMagic | BadVersion of int | Truncated

let magic_key = Crypto.magic_rgssad_prefix
let read_u32_le = Rgssad_core.read_u32_le

let parse (buf : bytes) : (entry list, parse_error) result =
  let len = Bytes.length buf in
  if len < 12 then Error ShortHeader
  else if not (Crypto.starts_with magic_key buf) then Error BadMagic
  else if Char.code (Bytes.get buf 7) <> 0x03 then
    Error (BadVersion (Char.code (Bytes.get buf 7)))
  else begin
    let master = Vxace_key.derive_master_key buf 8 in
    let pos = ref 12 in
    let idx = ref 0 in
    let acc = ref [] in
    let keep = ref true in
    while !keep do
      if !pos + 16 > len then keep := false
      else begin
        let raw_off = read_u32_le buf !pos in
        pos := !pos + 4;
        let raw_size = read_u32_le buf !pos in
        pos := !pos + 4;
        let raw_ekey = read_u32_le buf !pos in
        pos := !pos + 4;
        let raw_namelen = read_u32_le buf !pos in
        pos := !pos + 4;
        let off = Vxace_key.decode_u32 raw_off master in
        let sizev = Vxace_key.decode_u32 raw_size master in
        let ekey = Vxace_key.decode_u32 raw_ekey master in
        let nlen = Vxace_key.decode_u32 raw_namelen master in
        if off = 0 then keep := false
        else if !pos + nlen > len then begin
          acc := [];
          keep := false
        end
        else begin
          let namebytes = Bytes.sub buf !pos nlen in
          pos := !pos + nlen;
          let name = Vxace_key.decode_filename namebytes master in
          acc :=
            { index = !idx; name; offset = off; size = sizev; key = ekey }
            :: !acc;
          incr idx
        end
      end
    done;
    match !acc with [] -> Error Truncated | _ -> Ok (List.rev !acc)
  end

let parse_file (path : string) : (entry list, parse_error) result =
  parse (Io.read_file path)

(** Extract the raw payload for one entry from the archive buffer. *)
let read_entry (buf : bytes) (e : entry) : bytes =
  let start = e.offset in
  let len = Bytes.length buf in
  if start < 0 || start >= len then Bytes.create 0
  else begin
    let size = if start + e.size > len then len - start else e.size in
    Bytes.sub buf start size
  end

(** Decrypt a payload buffer using the per-entry rotation key. *)
let decrypt_payload (e : entry) (cipher : bytes) : bytes =
  Vxace_key.decode_payload cipher e.key
