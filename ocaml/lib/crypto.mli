(** XOR scheme, magic-byte detection, and hex-key decoding.

    Clean-room reimplementation; the algorithms (RPG Maker XOR, file-signature
    detection, 32-hex-char key parsing) match the public format specs
    byte-for-byte. All functions here are pure and total on valid input, raising
    [Invalid_argument] only on malformed arguments. *)

(* Uninterpreted helpers: Gospel 0.3.1 ships no Bytes/String/Char theory, so
   bytes/char operations are axiomatised as uninterpreted logic functions. The
   [xor_transform] / [sub_array_eq] / [hex_nibble] specs below are expressed in
   terms of them; they document the contract and are checked by ortac RAC and
   the QCheck property suite. *)
(*@ function bytes_length (b: bytes) : integer *)
(*@ function bytes_get (b: bytes) (i: integer) : char *)
(*@ function char_code (c: char) : integer *)
(*@ function char_chr (i: integer) : char *)

(** {1 Magic byte constants} *)

val magic_rgssad_prefix : bytes
(** The 7-byte RGSSAD archive magic, ["RGSSAD\000"]. *)

val magic_png : bytes
(** PNG signature (RFC 2083): [0x89 50 4E 47 0D 0A 1A 0A]. *)

val magic_ogg : bytes
val magic_m4a : bytes
val magic_riff : bytes
val magic_webp : bytes

val magic_jpg : bytes
(** File-signature prefixes used by plaintext detection. *)

(** {1 Substring / prefix comparison} *)

val sub_array_eq : int -> int -> bytes -> bytes -> bool
(** [sub_array_eq offset length expected arr] is [true] iff [arr] has at least
    [offset + length] bytes and [expected] has at least [length] bytes and the
    [length] bytes of [arr] starting at [offset] equal the first [length] bytes
    of [expected]. Returns [false] (never raises) when either buffer is too
    short. *)
(*@ r = sub_array_eq offset length expected arr
    ensures
      r =
        (bytes_length arr >= offset + length
         && bytes_length expected >= length
         && forall i.
                0 <= i < length -> bytes_get arr (offset + i) = bytes_get expected i) *)

val starts_with : bytes -> bytes -> bool
(** [starts_with prefix arr] is [true] iff [arr] begins with the bytes of
    [prefix]. Returns [false] when [arr] is shorter than [prefix]. *)
(*@ r = starts_with prefix arr
    ensures
      r =
        (bytes_length arr >= bytes_length prefix
         && forall i.
                0 <= i < bytes_length prefix -> bytes_get arr i = bytes_get prefix i) *)

(** {1 Plaintext detection} *)

val looks_like_plaintext : bytes -> bool
(** [looks_like_plaintext head] classifies the (first 16) bytes of an asset as a
    known unencrypted media signature (PNG, Ogg, JPEG, RIFF/WEBP, or M4A/ftyp).
    Returns [false] for an empty buffer or an unrecognised signature. *)
(*@ r = looks_like_plaintext head
    ensures r -> bytes_length head > 0 *)

(** {1 Hex key decoding} *)

val hex_nibble : char -> int
(** [hex_nibble c] is the numeric value of a single hex digit [c] ([0..15]).

    @raise Invalid_argument if [c] is not a hex digit. *)
(*@ r = hex_nibble c
    ensures
      match c with
      | '0' .. '9' -> r = char_code c - char_code '0'
      | 'a' .. 'f' -> r = char_code c - char_code 'a' + 10
      | _ -> false
    raises Invalid_argument _ ->
      not (match c with '0' .. '9' | 'a' .. 'f' -> true | _ -> false) *)

val decode_hex_key : string -> bytes
(** [decode_hex_key hex] lowercases, trims and decodes [hex] into a 16-byte key.

    @raise Invalid_argument unless [hex] (after trim) is exactly 32 hex chars.
*)
(*@ r = decode_hex_key hex
    ensures bytes_length r = 16
    raises Invalid_argument _ -> true *)

(** {1 XOR transform} *)

val xor_transform : bytes -> bytes -> bytes
(** [xor_transform key buf] XORs each byte of [buf] with [key] cyclically (index
    [i] uses [key] at [i mod length key]). Symmetric: applying it twice with the
    same key returns the original buffer.

    @raise Invalid_argument if [key] is empty. *)
(*@ r = xor_transform key buf
    requires bytes_length key > 0
    ensures bytes_length r = bytes_length buf
    ensures
      forall i.
        0 <= i < bytes_length buf ->
        bytes_get r i
        = char_chr
            (logxor (char_code (bytes_get buf i))
               (char_code (bytes_get key (mod i (bytes_length key))))) *)

(** {1 Format magic classifiers} *)

val is_mv_magic_header : bytes -> bool
(*@ r = is_mv_magic_header head
    ensures r -> bytes_length head >= 5 *)

val is_mz_magic_header : bytes -> bool
(*@ r = is_mz_magic_header head
    ensures r -> bytes_length head >= 5 *)

val is_rgssad_magic : bytes -> bool
(*@ r = is_rgssad_magic head
    ensures r -> bytes_length head >= bytes_length magic_rgssad_prefix *)

val is_zip_magic : bytes -> bool
(** [is_*_magic head] tests whether [head] begins with the corresponding format
    magic (RPGMV, RPGMZ, RGSSAD\000, or a ZIP local-file header [PK\x03\x04]).
    Safe on short buffers (return [false]). *)
(*@ r = is_zip_magic head
    ensures r -> bytes_length head >= 4 *)

val zero_fill : bytes -> unit
(** [zero_fill buf] overwrites [buf] entirely with NUL bytes. *)
