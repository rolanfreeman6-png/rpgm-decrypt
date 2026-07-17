(* MV/MZ individual-asset XOR decryption.
   cipher[i] = plain[i] XOR key[i mod keyLength]; symmetric. *)

type decrypt_outcome =
  | Plaintext of string * bytes (* kind, bytes — already plaintext, identity *)
  | Decrypted of string * bytes (* kind, bytes — XOR applied, magic found *)
  | Unsure of bytes (* XOR applied but no plaintext magic *)

type plaintext_kind = Png | Ogg | M4a | Webp | Jpg | Unknown

let classify_plaintext (head : bytes) : plaintext_kind =
  if Bytes.length head = 0 then Unknown
  else if Crypto.starts_with Crypto.magic_png head then Png
  else if Crypto.starts_with Crypto.magic_ogg head then Ogg
  else if
    Bytes.length head >= 8 && Crypto.sub_array_eq 4 4 Crypto.magic_m4a head
  then M4a
  else if
    Bytes.length head >= 12
    && Crypto.starts_with Crypto.magic_riff head
    && Crypto.sub_array_eq 8 4 Crypto.magic_webp head
  then Webp
  else if Crypto.starts_with Crypto.magic_jpg head then Jpg
  else Unknown

let plaintext_kind_to_string = function
  | Png -> "png"
  | Ogg -> "ogg"
  | M4a -> "m4a"
  | Webp -> "webp"
  | Jpg -> "jpg"
  | Unknown -> "bin"

(* The real RPG Maker MV/MZ asset format: a 16-byte fake header
   ("RPGMV\000..." — Crypto.magic_mv_header) prepended to the original file,
   whose first 16 bytes were XOR-ed byte-for-byte with the 16-byte key. The rest
   of the file is untouched plaintext. Decryption strips the header and un-XORs
   those first 16 bytes. *)
let header_len = 16
let encrypted_prefix_len = 16

(* Does [cipher] start with the 16-byte RPGMV/RPGMZ fake header? *)
let has_fake_header (cipher : bytes) : bool =
  Bytes.length cipher >= header_len
  && (Crypto.is_mv_magic_header cipher || Crypto.is_mz_magic_header cipher)

(* Strip the fake header and un-XOR the first 16 payload bytes with [key]. *)
let decrypt_header_scheme (key : bytes) (cipher : bytes) : bytes =
  let body = Bytes.sub cipher header_len (Bytes.length cipher - header_len) in
  let klen = Bytes.length key in
  let n = min encrypted_prefix_len (Bytes.length body) in
  for i = 0 to n - 1 do
    let v =
      Char.code (Bytes.get body i) lxor Char.code (Bytes.get key (i mod klen))
    in
    Bytes.set body i (Char.chr v)
  done;
  body

(** Decrypt a buffer believed to be an MV/MZ asset. Already-plaintext buffers
    are returned untouched (identity copy). *)
let decrypt (key : bytes) (cipher : bytes) : decrypt_outcome =
  if Bytes.length key = 0 then invalid_arg "MV key must not be empty";
  if Bytes.length cipher = 0 then Plaintext ("bin", cipher)
    (* empty -> pass through *)
  else if has_fake_header cipher then begin
    (* real RPG Maker scheme: header + first-16-XOR *)
    let plain = decrypt_header_scheme key cipher in
    let k = classify_plaintext plain in
    if k = Unknown then Unsure plain
    else Decrypted (plaintext_kind_to_string k, plain)
  end
  else if Crypto.looks_like_plaintext cipher then
    Plaintext (plaintext_kind_to_string (classify_plaintext cipher), cipher)
  else begin
    (* no fake header and not obviously plaintext: fall back to whole-file
       cyclic XOR (covers simple/older or repacked assets) *)
    let plain = Crypto.xor_transform key cipher in
    let k = classify_plaintext plain in
    if k = Unknown then Unsure plain
    else Decrypted (plaintext_kind_to_string k, plain)
  end

(** Centralised call so the Mv and Mz paths agree. *)
let decrypt_bytes (key : bytes) (cipher : bytes) : bytes * string =
  match decrypt key cipher with
  | Plaintext (kind, b) -> (b, kind)
  | Decrypted (kind, b) -> (b, kind)
  | Unsure b -> (b, "bin")
