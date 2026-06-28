(* Source — XOR scheme + magic-byte helpers + hex decode.
   F# byte[] -> OCaml bytes throughout. Clean-room reimplementation;
   same references as the F# version (rpgmakerweb.com docs, community wikis). *)

(* ---- Magic-byte constants (as bytes) ---------------------------------- *)
let magic_mv_header = Bytes.of_string "RPGMV"
let magic_mz_header = Bytes.of_string "RPGMZ"

(* 7 bytes "RGSSAD\0" — explicit so no escape-handling surprise. *)
let magic_rgssad_prefix =
  Bytes.of_string "\x52\x47\x53\x53\x41\x44\x00"

(* PNG signature (RFC 2083) — 0x89 is outside ASCII, hard-coded. *)
let magic_png = Bytes.of_string "\x89\x50\x4E\x47\x0D\x0A\x1A\x0A"
let magic_ogg = Bytes.of_string "OggS"
let magic_m4a = Bytes.of_string "ftyp"
let magic_riff = Bytes.of_string "RIFF"
let magic_webp = Bytes.of_string "WEBP"
let magic_jpg = Bytes.of_string "\xFF\xD8\xFF"

(** Equality of a fixed-size substring inside a larger buffer. *)
let sub_array_eq (offset : int) (length : int) (expected : bytes) (arr : bytes) :
    bool =
  if Bytes.length arr < offset + length then false
  else if Bytes.length expected < length then false
  else begin
    let ok = ref true in
    for i = 0 to length - 1 do
      if Bytes.get arr (offset + i) <> Bytes.get expected i then ok := false
    done;
    !ok
  end

(** Does [arr] start with the bytes of [prefix]? *)
let starts_with (prefix : bytes) (arr : bytes) : bool =
  if Bytes.length arr < Bytes.length prefix then false
  else sub_array_eq 0 (Bytes.length prefix) prefix arr

(** Was the ciphertext already plaintext? Caller passes the first 16 bytes. *)
let looks_like_plaintext (head : bytes) : bool =
  if Bytes.length head = 0 then false
  else
    starts_with magic_png head
    || starts_with magic_ogg head
    || starts_with magic_jpg head
    || (Bytes.length head >= 12 && starts_with magic_riff head
       && sub_array_eq 8 4 magic_webp head)
    || (Bytes.length head >= 8 && sub_array_eq 4 4 magic_m4a head)

(** Single hex character -> 0..15. Raises on bad char. *)
let hex_nibble (c : char) : int =
  match c with
  | '0' .. '9' -> Char.code c - Char.code '0'
  | 'a' .. 'f' -> Char.code c - Char.code 'a' + 10
  | _ -> invalid_arg (Printf.sprintf "non-hex char '%c'" c)

(** Decode a 32-char hex string into a 16-byte buffer. *)
let decode_hex_key (hex : string) : bytes =
  let cleaned = String.lowercase_ascii (String.trim hex) in
  if String.length cleaned <> 32 then
    invalid_arg
      (Printf.sprintf "encryption key must be 32 hex chars, got %d"
         (String.length cleaned));
  let b = Bytes.make 16 '\000' in
  for i = 0 to 15 do
    let hi = hex_nibble cleaned.[2 * i] in
    let lo = hex_nibble cleaned.[(2 * i) + 1] in
    Bytes.set b i (Char.chr ((hi lsl 4) lor lo))
  done;
  b

(** XOR [buf] against [key] cyclically. Symmetric — encrypt == decrypt. *)
let xor_transform (key : bytes) (buf : bytes) : bytes =
  if Bytes.length key = 0 then invalid_arg "XOR key must be non-empty";
  let n = Bytes.length buf in
  let out = Bytes.make n '\000' in
  let klen = Bytes.length key in
  for i = 0 to n - 1 do
    let v =
      Char.code (Bytes.get buf i) lxor Char.code (Bytes.get key (i mod klen))
    in
    Bytes.set out i (Char.chr v)
  done;
  out

let is_mv_magic_header (head : bytes) : bool =
  Bytes.length head >= Bytes.length magic_mv_header
  && starts_with magic_mv_header head

let is_mz_magic_header (head : bytes) : bool =
  Bytes.length head >= Bytes.length magic_mz_header
  && starts_with magic_mz_header head

let is_rgssad_magic (head : bytes) : bool =
  Bytes.length head >= Bytes.length magic_rgssad_prefix
  && starts_with magic_rgssad_prefix head

let is_zip_magic (head : bytes) : bool =
  Bytes.length head >= 4
  && Bytes.get head 0 = 'P'
  && Bytes.get head 1 = 'K'
  && Bytes.get head 2 = '\x03'
  && Bytes.get head 3 = '\x04'

let zero_fill (buf : bytes) : unit = Bytes.fill buf 0 (Bytes.length buf) '\000'
