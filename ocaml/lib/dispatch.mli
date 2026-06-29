(** Format classification and per-format dispatch.

    Port of the F# [Format] module: classify a file by extension and magic
    bytes, then route it to the appropriate decoder. *)

val classify : string -> Types.format option
(** [classify abs_path] inspects [abs_path]'s extension and first bytes and
    returns the detected {!Types.format}, or [None] if it is not a recognised
    RPG Maker file. Returns [None] (never raises) when the file is missing or
    unreadable. *)

val decrypt_single : bytes -> string -> (bytes * string * bool, string) result
(** [decrypt_single key abs_path] decrypts one MV/MZ asset at [abs_path].
    Returns [Ok (bytes, kind, was_decrypted)] — [was_decrypted] is [false] when
    the input was already plaintext. [Error msg] on I/O failure. *)

val decrypt_archive :
  bytes -> string -> ((string * bytes * string) list, string) result
(** [decrypt_archive key abs_path] decrypts a packed MZ [.pak] at [abs_path],
    returning a list of [(name, bytes, kind)] tuples. [Error msg] on open or
    decrypt failure. *)

val choose_output_extension : string -> string -> string
(** [choose_output_extension input_ext kind] maps a detected [kind] (or, for
    ["bin"], the original encrypted [input_ext]) to a real output extension.
    Total: always returns a valid extension. *)
