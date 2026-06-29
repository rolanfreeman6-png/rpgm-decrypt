(** Shared parser for XP (v0x01) and VX (v0x02) {.rgssad} archives.

    Both formats share the entry layout [size | offset | name_len | name];
    filenames are XOR-obfuscated with the 7-byte RGSSAD magic. Only the
    end-of-table sentinel differs between XP and VX (see {!sentinel}).

    Note vs F#: F# read each length field as [uint32] then cast to [int32], so a
    high-bit length went negative and was caught by [< 0]; OCaml's 63-bit [int]
    keeps it a large positive, caught by the [pos + len > buf_len] bounds check
    instead. Behaviour is identical ([Truncated]), with no negative wrap. *)

type entry = { index : int; name : string; offset : int; size : int }
(** One decoded archive entry. [offset] and [size] point into the archive buffer
    (ZLIB wrapping intact for the payload). *)

type parse_error = ShortHeader | BadMagic | BadVersion of int | Truncated
(** Failure modes: [ShortHeader] (< 8 bytes), [BadMagic] (no RGSSAD prefix),
    [BadVersion v] (version byte is [v]), [Truncated] (an entry ran past the
    buffer or the table contained no valid entry). *)

type sentinel =
  | NameLenZero  (** XP: terminates on [name_len = 0]. *)
  | SizeAndNameZero  (** VX: terminates on [name_len = 0 && size = 0]. *)

(** End-of-table rule — the only behavioural difference between XP and VX. *)

val magic_key : bytes
(** The XOR key used for filename obfuscation (equal to
    {!Crypto.magic_rgssad_prefix}). *)

val xor_decode_name : bytes -> string
(** [xor_decode_name raw] XOR-decodes [raw] against {!magic_key} cyclically and
    trims trailing NUL padding. *)

val read_u32_le : bytes -> int -> int
(** [read_u32_le buf pos] reads a little-endian unsigned 32-bit word at [pos].
    No bounds check: the caller ensures [pos + 3 < length buf]. *)

val parse :
  int -> sentinel -> bytes -> (entry list * int, parse_error) result
(** [parse version sentinel buf] parses the archive [buf] requiring version byte
    [version] and end-of-table rule [sentinel]. Returns
    [Ok (entries, end_pos)] on success, or an [Error] describing the failure.
    Never raises: corrupt or truncated input yields [Error Truncated] rather
    than an out-of-bounds access. *)

val read_entry : bytes -> entry -> bytes
(** [read_entry buf e] extracts the raw payload bytes for entry [e] from [buf],
    clamped to the buffer end (returns an empty buffer if [e.offset] is out of
    range). *)
