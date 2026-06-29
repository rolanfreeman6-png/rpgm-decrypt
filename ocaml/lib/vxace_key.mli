(** RGSS3 (VX Ace) key derivation and payload decryption.

    The F# version used [uint32] arithmetic (wrapping at 2^32); OCaml [int] is
    63-bit, so every multiply is masked with {!u32} to reproduce the wraparound
    exactly. *)

val u32 : int -> int
(** [u32 x] is [x land 0xFFFFFFFF] — reduce to the low 32 bits. *)

val derive_master_key : bytes -> int -> int
(** [derive_master_key buf seed_off] reads a little-endian seed at [seed_off]
    and returns [u32 (seed * 9 + 3)]. No bounds check: the caller ensures
    [seed_off + 3 < length buf]. *)

val decode_u32 : int -> int -> int
(** [decode_u32 cipher key] is [cipher lxor key] — XOR a u32 field
    (offset/size/entry-key/name_len). *)

val key_byte : int -> int -> int
(** [key_byte key j] is byte [j] (0..3) of [key] as a little-endian u32:
    [(key lsr (8 * j)) land 0xFF]. *)

val decode_filename : bytes -> int -> string
(** [decode_filename cipher master_key] decrypts a filename by XORing each byte
    with {!key_byte} of [master_key], cycling [j] through 0..3. *)

val decode_payload : bytes -> int -> bytes
(** [decode_payload cipher entry_key] decrypts a payload: every 4 bytes the
    running key is mutated by [tempKey = u32 (tempKey * 7 + 3)] and the byte
    index resets to 0. *)
