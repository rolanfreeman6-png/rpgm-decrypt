(** Small binary file helpers.

    Thin wrappers over stdlib binary channels, used throughout the library for
    reading whole files into [bytes] and writing [bytes] atomically. *)

val read_file : string -> bytes
(** [read_file path] is the full contents of [path] as bytes.

    @raise Sys_error if [path] cannot be opened or read. *)

val write_file : string -> bytes -> unit
(** [write_file path b] writes [b] to [path], truncating any existing file.

    @raise Sys_error on any I/O failure. *)
