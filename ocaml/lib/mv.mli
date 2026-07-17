(** RPG Maker MV/MZ individual-asset decryption.

    The real scheme prepends a 16-byte fake header ("RPGMV"/"RPGMZ" + id bytes)
    to the original file, whose first 16 bytes are XOR-ed byte-for-byte with the
    16-byte key; the rest is untouched plaintext. Decryption strips the header
    and un-XORs those 16 bytes. Buffers with no fake header fall back to
    whole-file cyclic XOR; already-plaintext assets are returned untouched. *)

type decrypt_outcome =
  | Plaintext of string * bytes
      (** (kind, bytes) — input was already plaintext *)
  | Decrypted of string * bytes
      (** (kind, bytes) — XOR applied, magic recovered *)
  | Unsure of bytes  (** XOR applied but no recognised magic *)

(** Outcome of {!decrypt}. [kind] is one of ["png"], ["ogg"], ["m4a"], ["webp"],
    ["jpg"], ["bin"]. *)

val decrypt : bytes -> bytes -> decrypt_outcome
(** [decrypt key cipher] classifies and (if needed) XOR-decrypts [cipher].

    @raise Invalid_argument if [key] is empty. *)

val decrypt_bytes : bytes -> bytes -> bytes * string
(** [decrypt_bytes key cipher] is the bytes+kind projection of {!decrypt}: the
    output bytes (possibly identity) and the detected kind string. *)
