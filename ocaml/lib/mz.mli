(** RPG Maker MZ [.pak] extraction.

    A [.pak] is a plain ZIP whose entries are individually MV-XOR-encrypted;
    this module opens it with camlzip and decrypts each entry. *)

type entry_result = {
  entry_name : string;
  plaintext_kind : string;
  bytes : bytes;
}
(** One decrypted [.pak] entry. *)

type open_error =
  | NotAZipFile
  | BadHeader of string
  | IOFailure of string  (** Failure modes for {!open_pak}. *)

val open_pak : string -> (Zip.in_file, open_error) result
(** [open_pak path] verifies the ZIP magic then opens [path] as a camlzip
    archive. Returns [Error NotAZipFile] if the magic is absent, or
    [Error (BadHeader _)] / [Error (IOFailure _)] on zip/I/O errors. *)

val decrypt_all : bytes -> Zip.in_file -> (entry_result list, string) result
(** [decrypt_all key z] decrypts every non-directory entry of [z] with [key]
    (via {!Mv.decrypt_bytes}), preserving archive order. Returns [Error msg] on
    any read failure. *)
