(* Port of RgssadCore.fs — shared XP (0x01) + VX (0x02) `.rgssad` parser.
   Identical layout `size|offset|name_len|name`, filenames XOR'd with the
   7-byte RGSSAD magic; the version byte and end-of-table sentinel differ.

   Note vs F#: F# read each field as uint32 then cast to int32 (which could go
   negative on a high-bit length, caught by `nameLenInt < 0`). OCaml's int is
   63-bit, so a 0xFFFFFFFx length stays a large POSITIVE int — the same corrupt
   input is caught by the `pos + name_len > len` bounds check instead. Behaviour
   is identical (Truncated), just no negative-wrap to guard against. *)

type entry =
  { index : int
  ; name : string
  ; offset : int
  ; size : int }

type parse_error =
  | ShortHeader
  | BadMagic
  | BadVersion of int
  | Truncated

(** End-of-table rule — the only behavioural difference between XP and VX. *)
type sentinel =
  | NameLenZero      (* XP: name_len = 0 terminates the table *)
  | SizeAndNameZero  (* VX: size = 0 && name_len = 0 terminates the table *)

let magic_key = Crypto.magic_rgssad_prefix

(** Filenames are XOR-obfuscated with the cycling magic prefix; trailing NULs
    (padding) are trimmed before decoding. *)
let xor_decode_name (raw : bytes) : string =
  let n = Bytes.length raw in
  if n = 0 then ""
  else begin
    let out = Bytes.make n '\000' in
    let keylen = Bytes.length magic_key in
    for i = 0 to n - 1 do
      let v =
        Char.code (Bytes.get raw i)
        lxor Char.code (Bytes.get magic_key (i mod keylen))
      in
      Bytes.set out i (Char.chr v)
    done;
    let endidx = ref n in
    while !endidx > 0 && Bytes.get out (!endidx - 1) = '\000' do
      decr endidx
    done;
    Bytes.sub_string out 0 !endidx
  end

let read_u32_le (buf : bytes) (pos : int) : int =
  Char.code (Bytes.get buf pos)
  lor (Char.code (Bytes.get buf (pos + 1)) lsl 8)
  lor (Char.code (Bytes.get buf (pos + 2)) lsl 16)
  lor (Char.code (Bytes.get buf (pos + 3)) lsl 24)

let parse (version : int) (sentinel : sentinel) (buf : bytes) :
    (entry list * int, parse_error) result =
  let len = Bytes.length buf in
  if len < 8 then Error ShortHeader
  else if not (Crypto.starts_with magic_key buf) then Error BadMagic
  else if Char.code (Bytes.get buf 7) <> version then
    Error (BadVersion (Char.code (Bytes.get buf 7)))
  else begin
    let pos = ref 8 in
    let idx = ref 0 in
    let acc = ref [] in (* reversed *)
    let keep = ref true in
    while !keep do
      if !pos + 12 > len then keep := false
      else begin
        let size = read_u32_le buf !pos in
        pos := !pos + 4;
        let offset = read_u32_le buf !pos in
        pos := !pos + 4;
        let name_len = read_u32_le buf !pos in
        pos := !pos + 4;
        let is_end =
          match sentinel with
          | NameLenZero -> name_len = 0
          | SizeAndNameZero -> name_len = 0 && size = 0
        in
        if is_end then keep := false
        else if !pos + name_len > len then begin
          acc := [];
          keep := false
        end
        else begin
          let namebytes = Bytes.sub buf !pos name_len in
          pos := !pos + name_len;
          acc :=
            { index = !idx; name = xor_decode_name namebytes; offset; size }
            :: !acc;
          incr idx
        end
      end
    done;
    match !acc with [] -> Error Truncated | _ -> Ok (List.rev !acc, !pos)
  end

(** Extract raw payload bytes for one entry (ZLIB wrapping intact). *)
let read_entry (buf : bytes) (e : entry) : bytes =
  let start = e.offset in
  let len = Bytes.length buf in
  if start < 0 || start >= len then Bytes.create 0
  else begin
    let size = if start + e.size > len then len - start else e.size in
    Bytes.sub buf start size
  end
