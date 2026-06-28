(* Source — Human + NDJSON sinks to stderr. *)

type format = Human | Json

type event =
  | Walked of string * int64
  | Detected of string * string
  | KeyFound of string
  | Decrypt of string * string * string
  | PassThrough of string
  | Skipped of string * string
  | Failed of string * string
  | Summary of Types.run_summary

let escape (s : string) : string =
  let b = Buffer.create (String.length s + 8) in
  String.iter
    (fun c ->
      match c with
      | '\\' -> Buffer.add_string b "\\\\"
      | '"' -> Buffer.add_string b "\\\""
      | '\n' -> Buffer.add_string b "\\n"
      | '\r' -> Buffer.add_string b "\\r"
      | '\t' -> Buffer.add_string b "\\t"
      | c when Char.code c < 32 -> Buffer.add_char b ' '
      | c -> Buffer.add_char b c)
    s;
  Buffer.contents b

let iso_of_time (t : float) : string =
  let tm = Unix.gmtime t in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ"
    (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1) tm.Unix.tm_mday tm.Unix.tm_hour
    tm.Unix.tm_min tm.Unix.tm_sec

let per_fmt_json (pf : (Types.format * int) list) : string =
  pf
  |> List.map (fun (k, v) ->
         Printf.sprintf "\"%s\":%d" (Types.format_to_string k) v)
  |> String.concat ","

let summary_to_json (s : Types.run_summary) : string =
  Printf.sprintf
    "{\"kind\":\"summary\",\"started\":\"%s\",\"finished\":\"%s\",\"scanned\":%d,\"decrypted\":%d,\"passthrough\":%d,\"skipped\":%d,\"failed\":%d,\"key_source\":\"%s\",\"per_format\":{%s}}"
    (escape (iso_of_time s.Types.started_at))
    (escape (iso_of_time s.Types.finished_at))
    s.Types.inputs_scanned s.Types.decrypted_count s.Types.passed_through_count
    s.Types.skipped_count s.Types.failed_count (escape s.Types.key_source)
    (per_fmt_json s.Types.per_format)

let event_to_json (e : event) : string =
  match e with
  | Walked (p, sz) ->
      Printf.sprintf "{\"kind\":\"walked\",\"path\":\"%s\",\"size\":%Ld}"
        (escape p) sz
  | Detected (p, fmt) ->
      Printf.sprintf "{\"kind\":\"detected\",\"path\":\"%s\",\"format\":\"%s\"}"
        (escape p) (escape fmt)
  | KeyFound src ->
      Printf.sprintf "{\"kind\":\"key_found\",\"source\":\"%s\"}" (escape src)
  | Decrypt (i, o, fmt) ->
      Printf.sprintf
        "{\"kind\":\"decrypt\",\"input\":\"%s\",\"output\":\"%s\",\"format\":\"%s\"}"
        (escape i) (escape o) (escape fmt)
  | PassThrough p ->
      Printf.sprintf "{\"kind\":\"passthrough\",\"path\":\"%s\"}" (escape p)
  | Skipped (p, r) ->
      Printf.sprintf "{\"kind\":\"skipped\",\"path\":\"%s\",\"reason\":\"%s\"}"
        (escape p) (escape r)
  | Failed (p, r) ->
      Printf.sprintf "{\"kind\":\"failed\",\"path\":\"%s\",\"reason\":\"%s\"}"
        (escape p) (escape r)
  | Summary s -> summary_to_json s

let human_summary (s : Types.run_summary) : string =
  let dur = s.Types.finished_at -. s.Types.started_at in
  let per_fmt_line =
    s.Types.per_format
    |> List.map (fun (k, v) ->
           Printf.sprintf "%s=%d" (Types.format_to_string k) v)
    |> String.concat " "
  in
  Printf.sprintf
    "scanned: %d\ndecrypted: %d\npass-through: %d\nskipped: %d\nfailed: %d\nkey \
     source: %s\nduration: %.2fs\nby format: %s"
    s.Types.inputs_scanned s.Types.decrypted_count s.Types.passed_through_count
    s.Types.skipped_count s.Types.failed_count s.Types.key_source dur
    per_fmt_line

(** Emit one event to STDERR using the chosen format. *)
let emit (fmt : format) (e : event) : unit =
  match fmt with
  | Human -> (
      match e with
      | Walked (p, sz) -> Printf.eprintf "walked %s (%Ld B)\n" p sz
      | Detected (p, f) -> Printf.eprintf "  + detected %s as %s\n" p f
      | KeyFound src -> Printf.eprintf "[key] %s\n" src
      | Decrypt (i, o, f) -> Printf.eprintf "  > %s -> %s [%s]\n" i o f
      | PassThrough p -> Printf.eprintf "  = %s (already plaintext)\n" p
      | Skipped (p, r) -> Printf.eprintf "  - skipped %s (%s)\n" p r
      | Failed (p, r) -> Printf.eprintf "  x failed %s (%s)\n" p r
      | Summary s -> Printf.eprintf "\n=== summary ===\n%s\n" (human_summary s))
  | Json -> Printf.eprintf "%s\n" (event_to_json e)
