(** Recursive directory walker yielding detected files.

    Port of the F# [Walk] module. The F# [walkWithProgress] helper was dead code
    and is not ported. *)

val walk : string -> Types.detected_file list
(** [walk root_dir] recursively lists files under [root_dir] whose extension is
    a recognised RPG Maker asset/archive extension and which
    {!Dispatch.classify} accepts. Returns [[]] (never raises) if [root_dir] is
    missing or not a directory. *)
