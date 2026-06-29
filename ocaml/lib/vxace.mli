(** RPG Maker VX Ace [.rgss3a] (version 0x03).

    The master seed at byte 8 yields [masterKey = seed * 9 + 3]; every entry
    field (offset/size/entry-key/name_len) is XOR'd with [masterKey], and each
    payload is decrypted with the per-entry rotating key (see {!Vxace_key}). *)

type entry = { index : int; name : string; offset : int; size : int; key : int }
(** One decoded RGSS3 entry. [key] is the per-entry payload key. *)

type parse_error =
  | ShortHeader
  | BadMagic
  | BadVersion of int
  | Truncated  (** Failure modes, mirroring {!Rgssad_core.parse_error}. *)

val parse : bytes -> (entry list, parse_error) result
(** Parse an [.rgss3a] buffer. Returns [Ok entries] or an [Error]. Never raises
    on corrupt/truncated input (yields [Error Truncated]). *)

val parse_file : string -> (entry list, parse_error) result
(** [parse_file path] reads [path] and parses it. *)

val read_entry : bytes -> entry -> bytes
(** Extract the raw (still-encrypted) payload for [e] from [buf], clamped to the
    buffer end. *)

val decrypt_payload : entry -> bytes -> bytes
(** [decrypt_payload e cipher] decrypts [cipher] with [e.key] via
    {!Vxace_key.decode_payload}. *)
