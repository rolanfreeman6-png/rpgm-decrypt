(* Port of the CLI module — CLI front-end: arg parsing, key resolution, Report.run,
   exit codes (0 ok / 2 usage / 3 io / 4 no-key / 5 partial). *)

open Rpgm

let run_summary_to_json (s : Types.run_summary) : string =
  let per =
    s.Types.per_format
    |> List.map (fun (k, v) ->
        Printf.sprintf "\"%s\":%d" (Types.format_to_string k) v)
    |> String.concat ","
  in
  Printf.sprintf
    "{\"scanned\":%d,\"decrypted\":%d,\"passthrough\":%d,\"skipped\":%d,\"failed\":%d,\"key_source\":\"%s\",\"per_format\":{%s}}"
    s.Types.inputs_scanned s.Types.decrypted_count s.Types.passed_through_count
    s.Types.skipped_count s.Types.failed_count s.Types.key_source per

let run_summary_human (s : Types.run_summary) : string =
  let per =
    s.Types.per_format
    |> List.map (fun (k, v) ->
        Printf.sprintf "%s=%d" (Types.format_to_string k) v)
    |> String.concat " "
  in
  Printf.sprintf
    "scanned=%d decrypted=%d passthrough=%d skipped=%d failed=%d key=%s \
     formats=[%s]"
    s.Types.inputs_scanned s.Types.decrypted_count s.Types.passed_through_count
    s.Types.skipped_count s.Types.failed_count s.Types.key_source per

let bytes_of_hex (hex : string) : bytes =
  let n = String.length hex / 2 in
  let b = Bytes.make n '\000' in
  for i = 0 to n - 1 do
    let hi = Crypto.hex_nibble (Char.lowercase_ascii hex.[2 * i]) in
    let lo = Crypto.hex_nibble (Char.lowercase_ascii hex.[(2 * i) + 1]) in
    Bytes.set b i (Char.chr ((hi lsl 4) lor lo))
  done;
  b

let usage () =
  print_string
    "Usage: rpgm-decrypt [OPTIONS] <game_dir> [<out_dir>]\n\n\
     Options:\n\
    \  --password <hex>             32-char hex key for MV/MZ\n\
    \  --password-file <path>       newline-separated candidate keys\n\
    \  --vxace-seed <8hex>          RPG Maker VX Ace master-seed (8 hex chars)\n\
    \  --log-format human|json      stderr log format (default human)\n\
    \  --report-format human|json   final stdout report (default human)\n\
    \  --dry-run                    walk + classify, write nothing\n\
    \  --quiet                      no per-file progress\n\
    \  -h, --help                   this help\n\
    \  --version                    version + supported formats\n\n\
     Exit codes: 0=ok 2=usage 3=io 4=no-key 5=partial\n"

let () =
  let argv = Sys.argv in
  let n = Array.length argv in
  let help = ref false and version = ref false and quiet = ref false in
  let dry_run = ref false and err_num = ref 0 in
  let log_fmt = ref Log.Human and rep_fmt = ref Log.Human in
  let password = ref None
  and password_file = ref None
  and vxace_seed = ref None in
  let pos = ref [] in
  let i = ref 1 in
  let need_val name =
    if !i + 1 >= n then begin
      Printf.eprintf "error: %s requires a value\n" name;
      incr err_num;
      None
    end
    else begin
      incr i;
      Some argv.(!i)
    end
  in
  while !i < n do
    (match argv.(!i) with
    | "-h" | "--help" -> help := true
    | "--version" -> version := true
    | "--quiet" -> quiet := true
    | "--dry-run" -> dry_run := true
    | "--log-format" -> (
        match need_val "--log-format" with
        | Some v -> (
            match String.lowercase_ascii v with
            | "json" -> log_fmt := Log.Json
            | "human" -> log_fmt := Log.Human
            | _ ->
                Printf.eprintf "error: --log-format must be human|json\n";
                incr err_num)
        | None -> ())
    | "--report-format" -> (
        match need_val "--report-format" with
        | Some v -> (
            match String.lowercase_ascii v with
            | "json" -> rep_fmt := Log.Json
            | "human" -> rep_fmt := Log.Human
            | _ ->
                Printf.eprintf "error: --report-format must be human|json\n";
                incr err_num)
        | None -> ())
    | "--password" -> (
        match need_val "--password" with
        | Some v -> password := Some v
        | None -> ())
    | "--password-file" -> (
        match need_val "--password-file" with
        | Some v -> password_file := Some v
        | None -> ())
    | "--vxace-seed" -> (
        match need_val "--vxace-seed" with
        | Some v -> vxace_seed := Some v
        | None -> ())
    | a when String.length a >= 2 && a.[0] = '-' && a.[1] = '-' ->
        Printf.eprintf "error: unknown option %s\n" a;
        incr err_num
    | a -> pos := a :: !pos);
    incr i
  done;
  let pos = List.rev !pos in

  if !version then begin
    Printf.printf "rpgm-decrypt 0.3.0\n";
    Printf.printf "  engine support: XP / VX / VX Ace / MV / MZ\n";
    Printf.printf "  built on OCaml %s\n" Sys.ocaml_version;
    exit !err_num
  end;

  if !help || !err_num <> 0 then begin
    usage ();
    exit (if !err_num <> 0 then 2 else 0)
  end;

  (match pos with
  | [] ->
      Printf.eprintf "error: missing <game_dir>\n";
      exit 2
  | _ -> ());

  let game_dir = List.nth pos 0 in
  let out_dir =
    if List.length pos >= 2 then List.nth pos 1
    else begin
      let parent =
        match Filename.dirname game_dir with "" -> game_dir | p -> p
      in
      let trimmed =
        let g = game_dir in
        let len = ref (String.length g) in
        while !len > 0 && g.[!len - 1] = '/' do
          decr len
        done;
        String.sub g 0 !len
      in
      let stem =
        match Filename.basename trimmed with "" | "." | "/" -> "game" | b -> b
      in
      Filename.concat parent ("rpgm-decrypted-" ^ stem)
    end
  in

  if not (Sys.file_exists game_dir && Sys.is_directory game_dir) then begin
    Printf.eprintf "error: game_dir not found: %s\n" game_dir;
    exit 3
  end;

  let key_result : Key_discovery.key_result =
    match (!password, !password_file, !vxace_seed) with
    | Some p, _, _ -> (
        try Key_discovery.Found (Crypto.decode_hex_key p, "--password flag")
        with e ->
          Printf.eprintf "error: invalid --password: %s\n"
            (Printexc.to_string e);
          exit 2)
    | None, Some pf, _ ->
        if not (Sys.file_exists pf) then begin
          Printf.eprintf "error: --password-file not found: %s\n" pf;
          exit 3
        end;
        let words =
          Bytes.to_string (Io.read_file pf)
          |> String.split_on_char '\n' |> List.map String.trim
          |> List.filter (fun s -> String.length s > 0)
          |> Array.of_list
        in
        Key_discovery.discover_with_wordlist game_dir words
    | None, None, Some seed_hex ->
        if String.length seed_hex <> 8 then begin
          Printf.eprintf
            "error: --vxace-seed requires exactly 8 hex chars (got %d)\n"
            (String.length seed_hex);
          exit 2
        end;
        let seed_bytes =
          try bytes_of_hex seed_hex
          with e ->
            Printf.eprintf "error: --vxace-seed: invalid hex: %s\n"
              (Printexc.to_string e);
            exit 2
        in
        let master_key =
          Vxace_key.u32
            (Char.code (Bytes.get seed_bytes 0)
            lor (Char.code (Bytes.get seed_bytes 1) lsl 8)
            lor (Char.code (Bytes.get seed_bytes 2) lsl 16)
            lor (Char.code (Bytes.get seed_bytes 3) lsl 24))
        in
        let derived = Bytes.make 16 '\000' in
        let rotating = ref (Vxace_key.u32 ((master_key * 9) + 3)) in
        for j = 0 to 15 do
          Bytes.set derived j (Char.chr (!rotating land 0xFF));
          rotating := Vxace_key.u32 ((!rotating * 7) + 3)
        done;
        Key_discovery.Found
          ( derived,
            Printf.sprintf "--vxace-seed derived from master=0x%08X" master_key
          )
    | None, None, None -> Key_discovery.discover game_dir
  in

  match key_result with
  | Key_discovery.NotFound why ->
      Printf.eprintf "error: no encryption key recovered (%s)\n" why;
      Printf.eprintf
        "       supply --password <hex32>, --password-file <list>, or \
         --vxace-seed <8hex>\n";
      exit 4
  | Key_discovery.Found (key_bytes, src) ->
      let summary =
        Report.run
          {
            Report.game_dir;
            out_dir;
            key = key_bytes;
            key_source = src;
            dry_run = !dry_run;
            on_event = (if !quiet then fun _ -> () else Log.emit !log_fmt);
          }
      in
      Crypto.zero_fill key_bytes;
      (match !rep_fmt with
      | Log.Json -> print_endline (run_summary_to_json summary)
      | Log.Human -> print_endline (run_summary_human summary));
      if summary.Types.failed_count = 0 then exit 0 else exit 5
