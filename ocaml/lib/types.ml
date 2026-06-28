(* Source — engine formats, per-file outcome, run summary.
   F# discriminated unions -> OCaml variants; F# records -> OCaml records;
   F# Map<Format,int> -> an (format * int) assoc list (small, fixed key set). *)

(** RPG Maker engine generation. Discriminator for the format dispatcher. *)
type format =
  | XP     (* RPG Maker XP, archive: .rgssad (version 0x01) *)
  | VX     (* RPG Maker VX, archive: .rgssad (version 0x02) or .rgss2a *)
  | VXAce  (* RPG Maker VX Ace, archive: .rgss3a (version 0x03) *)
  | MV     (* RPG Maker MV, individual XOR-encrypted assets *)
  | MZ     (* RPG Maker MZ, .pak ZIP containing MV-scheme encrypted assets *)

let format_to_string = function
  | XP -> "XP"
  | VX -> "VX"
  | VXAce -> "VXAce"
  | MV -> "MV"
  | MZ -> "MZ"

let format_of_string = function
  | "XP" -> Some XP
  | "VX" -> Some VX
  | "VXAce" -> Some VXAce
  | "MV" -> Some MV
  | "MZ" -> Some MZ
  | _ -> None

(** A file we inspected while walking the user's game directory. *)
type detected_file =
  { abs_path : string
  ; rel_path : string
  ; size_bytes : int64
  ; format : format }

(** What we did with one input file. *)
type outcome =
  | Decrypted of string * int64 * format   (* relOutPath, bytesWritten, format *)
  | PassedThrough of string * format       (* relOutPath, format *)
  | Skipped of string * string             (* inputRelPath, reason *)
  | Failed of string * string              (* inputRelPath, reason *)

(** End-of-run numbers. The CLI emits JSON for this. *)
type run_summary =
  { started_at : float            (* Unix time, seconds *)
  ; finished_at : float
  ; inputs_scanned : int
  ; decrypted_count : int
  ; passed_through_count : int
  ; skipped_count : int
  ; failed_count : int
  ; per_format : (format * int) list
  ; key_source : string
  ; errors : (string * string) list }

let run_summary_empty (now : float) : run_summary =
  { started_at = now
  ; finished_at = now
  ; inputs_scanned = 0
  ; decrypted_count = 0
  ; passed_through_count = 0
  ; skipped_count = 0
  ; failed_count = 0
  ; per_format = []
  ; key_source = "none"
  ; errors = [] }

let bump_fmt (s : run_summary) (fmt : format) : run_summary =
  let rec go = function
    | [] -> [ (fmt, 1) ]
    | (k, n) :: rest when k = fmt -> (k, n + 1) :: rest
    | kv :: rest -> kv :: go rest
  in
  { s with per_format = go s.per_format }

let tally (o : outcome) (s : run_summary) : run_summary =
  match o with
  | Decrypted (_, _, fmt) ->
      bump_fmt { s with decrypted_count = s.decrypted_count + 1 } fmt
  | PassedThrough (_, fmt) ->
      bump_fmt { s with passed_through_count = s.passed_through_count + 1 } fmt
  | Skipped (_, _) -> { s with skipped_count = s.skipped_count + 1 }
  | Failed (_, _) -> { s with failed_count = s.failed_count + 1 }
