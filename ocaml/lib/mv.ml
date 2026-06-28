(* Source — MV/MZ individual-asset XOR decryption.
   cipher[i] = plain[i] XOR key[i mod keyLength]; symmetric. *)

type decrypt_outcome =
  | Plaintext of string * bytes  (* kind, bytes — already plaintext, identity *)
  | Decrypted of string * bytes  (* kind, bytes — XOR applied, magic found *)
  | Unsure of bytes              (* XOR applied but no plaintext magic *)

type plaintext_kind = Png | Ogg | M4a | Webp | Jpg | Unknown

let classify_plaintext (head : bytes) : plaintext_kind =
  if Bytes.length head = 0 then Unknown
  else if Crypto.starts_with Crypto.magic_png head then Png
  else if Crypto.starts_with Crypto.magic_ogg head then Ogg
  else if Bytes.length head >= 8 && Crypto.sub_array_eq 4 4 Crypto.magic_m4a head
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

(** Decrypt a buffer believed to be MV/MZ XOR-encrypted. Already-plaintext
    buffers are returned untouched (identity copy). *)
let decrypt (key : bytes) (cipher : bytes) : decrypt_outcome =
  if Bytes.length key = 0 then invalid_arg "MV key must not be empty";
  if Bytes.length cipher = 0 then Plaintext ("bin", cipher) (* empty -> pass through *)
  else if Crypto.looks_like_plaintext cipher then
    Plaintext (plaintext_kind_to_string (classify_plaintext cipher), cipher)
  else begin
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
