(* Source — RGSS3 (VX Ace) key derivation + payload decryption.
   F# used uint32 arithmetic (wraps at 2^32). OCaml int is 63-bit, so we mask
   with [u32] after each multiply to reproduce the wraparound exactly. *)

let u32 x = x land 0xFFFFFFFF

(** Master key: read 4 LE bytes at [seed_off], then masterKey = seed*9 + 3. *)
let derive_master_key (buf : bytes) (seed_off : int) : int =
  let seed =
    Char.code (Bytes.get buf seed_off)
    lor (Char.code (Bytes.get buf (seed_off + 1)) lsl 8)
    lor (Char.code (Bytes.get buf (seed_off + 2)) lsl 16)
    lor (Char.code (Bytes.get buf (seed_off + 3)) lsl 24)
  in
  u32 ((seed * 9) + 3)

(** XOR a u32 field (offset/size/per-entry-key/name_len). *)
let decode_u32 (cipher : int) (key : int) : int = cipher lxor key

(** Byte [j] (0..3) of a little-endian u32, no allocation. *)
let key_byte (key : int) (j : int) : int = (key lsr (8 * j)) land 0xFF

(** Decrypt a filename byte stream, cycling the 4-byte master key per byte. *)
let decode_filename (cipher : bytes) (master_key : int) : string =
  let n = Bytes.length cipher in
  let out = Bytes.make n '\000' in
  let j = ref 0 in
  for i = 0 to n - 1 do
    Bytes.set out i
      (Char.chr (Char.code (Bytes.get cipher i) lxor key_byte master_key !j));
    j := if !j = 3 then 0 else !j + 1
  done;
  Bytes.to_string out

(** Decrypt a payload byte stream. Every 4 bytes the running key is mutated by
    tempKey = tempKey*7 + 3 and the byte index cycles back to 0. *)
let decode_payload (cipher : bytes) (entry_key : int) : bytes =
  let n = Bytes.length cipher in
  let out = Bytes.make n '\000' in
  let temp_key = ref entry_key in
  let j = ref 0 in
  for i = 0 to n - 1 do
    Bytes.set out i
      (Char.chr (Char.code (Bytes.get cipher i) lxor key_byte !temp_key !j));
    incr j;
    if !j = 4 then begin
      temp_key := u32 ((!temp_key * 7) + 3);
      j := 0
    end
  done;
  out
