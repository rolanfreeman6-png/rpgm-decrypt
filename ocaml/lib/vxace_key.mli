(** RGSS3 (VX Ace) key derivation and payload decryption.

    The arithmetic wraps at 2^32; OCaml [int] is 63-bit, so every multiply is
    masked with {!u32} to reproduce the wraparound exactly. *)

(* Uninterpreted helpers: Gospel 0.3.1 ships no Bytes/String theory, so the
   bytes/string operations below are axiomatised as uninterpreted logic
   functions. The integer-only specs ([u32], [decode_u32], [key_byte]) are fully
   grounded in Gospel's built-in integer/bitwise theory. *)
(*@ function bytes_length (b: bytes) : integer *)
(*@ function string_length (s: string) : integer *)
(*@ function read_u32_le_at (b: bytes) (o: integer) : integer *)

val u32 : int -> int
(** [u32 x] is [x land 0xFFFFFFFF] — reduce to the low 32 bits. *)
(*@ r = u32 x
    ensures r = logand x 4294967295 *)

val derive_master_key : bytes -> int -> int
(** [derive_master_key buf seed_off] reads a little-endian seed at [seed_off]
    and returns [u32 (seed * 9 + 3)]. No bounds check: the caller ensures
    [seed_off + 3 < length buf]. *)
(*@ r = derive_master_key buf seed_off
    requires 0 <= seed_off
    requires seed_off + 4 <= bytes_length buf
    ensures r = logand ((read_u32_le_at buf seed_off * 9) + 3) 4294967295 *)

val decode_u32 : int -> int -> int
(** [decode_u32 cipher key] is [cipher lxor key] — XOR a u32 field
    (offset/size/entry-key/name_len). *)
(*@ r = decode_u32 cipher key
    ensures r = logxor cipher key *)

val key_byte : int -> int -> int
(** [key_byte key j] is byte [j] (0..3) of [key] as a little-endian u32:
    [(key lsr (8 * j)) land 0xFF]. *)
(*@ r = key_byte key j
    requires 0 <= j <= 3
    ensures r = logand (shift_right key (8 * j)) 255 *)

val decode_filename : bytes -> int -> string
(** [decode_filename cipher master_key] decrypts a filename by XORing each byte
    with {!key_byte} of [master_key], cycling [j] through 0..3. *)
(*@ r = decode_filename cipher master_key
    ensures string_length r = bytes_length cipher *)

val decode_payload : bytes -> int -> bytes
(** [decode_payload cipher entry_key] decrypts a payload: every 4 bytes the
    running key is mutated by [tempKey = u32 (tempKey * 7 + 3)] and the byte
    index resets to 0. *)
(*@ r = decode_payload cipher entry_key
    ensures bytes_length r = bytes_length cipher *)
