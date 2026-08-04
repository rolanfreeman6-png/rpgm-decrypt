(** RGSSAD v1 parser + payload decryptor, shared by RPG Maker XP ([.rgssad])
    and VX ([.rgss2a]). Both use the same on-disk format whose version byte is
    [0x01]; there is no RGSSAD "v2" (VX Ace's [.rgss3a] is v3, see {!Vxace}).

    The format is a stream: a single rolling key seeded with [0xDEADCAFE] is
    mutated [key = (key*7 + 3) mod 2^32] after every 32-bit field and after each
    filename byte. From offset 8 to EOF each entry is
    [name_len:u32 | name:name_len | size:u32 | data:size]. Payload [data] is left
    encrypted in place and decrypted on demand by {!decrypt_data}.

    Length fields are read as little-endian 32-bit words into OCaml's 63-bit
    [int]; a corrupt high-bit length stays a large positive, caught by the
    [pos + len > buf_len] bounds check. Result is [Truncated], never an
    out-of-bounds access. *)

(* Uninterpreted helpers (Gospel 0.3.1 has no Bytes/String theory). *)
(*@ function bytes_length (b: bytes) : integer *)
(*@ function bytes_get_int (b: bytes) (i: integer) : integer *)

type entry = { index : int; name : string; offset : int; size : int; key : int }
(** One decoded archive entry. [offset]/[size] delimit the still-encrypted
    payload within the archive buffer; [key] is the rolling-key value captured
    immediately after the entry's [size] field, used by {!decrypt_data}. [name]
    has any backslash separators normalised to ['/']. *)

type parse_error =
  | ShortHeader
  | BadMagic
  | BadVersion of int
  | Truncated
      (** Failure modes: [ShortHeader] (< 8 bytes), [BadMagic] (no RGSSAD
          prefix), [BadVersion v] (version byte is [v], expected [0x01]),
          [Truncated] (an entry ran past the buffer or no valid entry). *)

val read_u32_le : bytes -> int -> int
(** [read_u32_le buf pos] reads a little-endian unsigned 32-bit word at [pos].
    No bounds check: the caller ensures [pos + 3 < length buf]. *)
(*@ r = read_u32_le buf pos
    requires 0 <= pos
    requires pos + 4 <= bytes_length buf
    ensures
      r =
        logor
          (bytes_get_int buf pos)
          (logor (shift_left (bytes_get_int buf (pos + 1)) 8)
             (logor (shift_left (bytes_get_int buf (pos + 2)) 16)
                (shift_left (bytes_get_int buf (pos + 3)) 24))) *)

val parse : bytes -> (entry list * int, parse_error) result
(** [parse buf] parses the RGSSAD v1 archive [buf] (version byte must be
    [0x01]). Returns [Ok (entries, end_pos)] on success, or an [Error]
    describing the failure. Never raises: corrupt or truncated input yields
    [Error Truncated] rather than an out-of-bounds access. *)
(*@ r = parse buf
    ensures
      match r with
      | Ok (_, p) -> 0 <= p && p <= bytes_length buf
      | Error _ -> true *)

val read_entry : bytes -> entry -> bytes
(** [read_entry buf e] extracts the raw (still-encrypted) payload bytes for
    entry [e] from [buf], clamped to the buffer end (returns an empty buffer if
    [e.offset] is out of range). *)
(*@ r = read_entry buf e
    ensures bytes_length r <= e.size
    ensures (e.offset < 0 || e.offset >= bytes_length buf) -> bytes_length r = 0 *)

val decrypt_data : entry -> bytes -> bytes
(** [decrypt_data e cipher] decrypts an entry's payload: each byte is XOR'd with
    the matching little-endian byte of the running key, which advances
    [key = key*7+3] every 4 bytes starting from [e.key]. The result has the same
    length as [cipher]. *)
(*@ r = decrypt_data e cipher
    ensures bytes_length r = bytes_length cipher *)
