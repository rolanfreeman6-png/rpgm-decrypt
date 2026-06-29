(** Human and NDJSON logging sinks to stderr.

    Logs go to stderr only. *)

type format =
  | Human
  | Json
      (** Output style: [Human] (free text) or [Json] (one JSON object per
          line). *)

type event =
  | Walked of string * int64
  | Detected of string * string
  | KeyFound of string
  | Decrypt of string * string * string
  | PassThrough of string
  | Skipped of string * string
  | Failed of string * string
  | Summary of Types.run_summary
      (** A single log event emitted during a run. *)

val escape : string -> string
(** [escape s] JSON-escapes [s] (quote, backslash, control chars). *)

val summary_to_json : Types.run_summary -> string
(** [summary_to_json s] renders [s] as a single JSON object string. *)

val emit : format -> event -> unit
(** [emit fmt e] writes [e] to stderr in the chosen [fmt]. *)
