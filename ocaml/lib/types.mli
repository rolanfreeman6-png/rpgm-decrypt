(** RPG Maker engine formats, per-file outcomes, and run summaries.

    [format] is a variant over the five engine generations; [detected_file],
    [outcome], and [run_summary] are records; the per-format tally is an
    association list (the key set is small and fixed). *)

type format =
  | XP  (** RPG Maker XP, archive [.rgssad] version 0x01. *)
  | VX  (** RPG Maker VX, archive [.rgssad] version 0x02 or [.rgss2a]. *)
  | VXAce  (** RPG Maker VX Ace, archive [.rgss3a] version 0x03. *)
  | MV  (** RPG Maker MV, individual XOR-encrypted assets. *)
  | MZ  (** RPG Maker MZ, [.pak] ZIP of MV-scheme encrypted assets. *)

val format_to_string : format -> string
(** Canonical short name of a format ([XP], [VX], [VXAce], [MV], [MZ]). *)

val format_of_string : string -> format option
(** Inverse of {!format_to_string}; [None] for an unknown name. *)

type detected_file = {
  abs_path : string;
  rel_path : string;
  size_bytes : int64;
  format : format;
}
(** A file discovered while walking the game directory. *)

type outcome =
  | Decrypted of string * int64 * format  (** (relOutPath, bytesWritten, fmt) *)
  | PassedThrough of string * format  (** (relOutPath, fmt) *)
  | Skipped of string * string  (** (inputRelPath, reason) *)
  | Failed of string * string  (** (inputRelPath, reason) *)

(** What the orchestrator did with one input file. *)

type run_summary = {
  started_at : float;
  finished_at : float;
  inputs_scanned : int;
  decrypted_count : int;
  passed_through_count : int;
  skipped_count : int;
  failed_count : int;
  per_format : (format * int) list;
  key_source : string;
  errors : (string * string) list;
}
(** End-of-run counters; [per_format] is an association list keyed by {!format}.
*)

val run_summary_empty : float -> run_summary
(** [run_summary_empty now] is a summary with zeroed counters and [now] as both
    start and finish time. *)

val tally : outcome -> run_summary -> run_summary
(** [tally o s] folds one file outcome into [s], bumping the relevant counter
    and the per-format tally (for [Decrypted]/[PassedThrough]). *)
