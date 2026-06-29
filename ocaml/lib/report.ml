(* Source — orchestrator: walk -> classify -> decrypt -> write a
   mirror tree under out_dir, building a run_summary. Includes the Zip-Slip
   containment check (safe_join, C-2) and the MZ argument-order fix (I-5). *)

type config = {
  game_dir : string;
  out_dir : string;
  key : bytes;
  key_source : string;
  dry_run : bool;
  on_event : Log.event -> unit;
}

(* ---- filesystem helpers (mkdir -p, since OCaml's is single-level) ----- *)
let rec mkdir_p (dir : string) : unit =
  if dir = "" || dir = "." || dir = "/" || Sys.file_exists dir then ()
  else begin
    mkdir_p (Filename.dirname dir);
    try Unix.mkdir dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ()
  end

let write_all_bytes (path : string) (b : bytes) : unit =
  let dir = Filename.dirname path in
  if dir <> "" && not (Sys.file_exists dir) then mkdir_p dir;
  Io.write_file path b

let copy_through (src : string) (dst : string) : unit =
  let dir = Filename.dirname dst in
  if dir <> "" && not (Sys.file_exists dir) then mkdir_p dir;
  Io.write_file dst (Io.read_file src)

let strip_encryption_extension (path : string) : string =
  if String.length path > 0 && path.[String.length path - 1] = '_' then
    String.sub path 0 (String.length path - 1)
  else path

let rename_by_kind (rel_path : string) (kind : string) : string =
  match kind with
  | "png" | "ogg" | "m4a" -> strip_encryption_extension rel_path
  | "webp" ->
      let dir = Filename.dirname rel_path in
      let stem = Filename.remove_extension (Filename.basename rel_path) in
      let ext = "." ^ kind in
      if dir = "" || dir = "." then stem ^ ext
      else Filename.concat dir (stem ^ ext)
  | _ -> rel_path

(* ---- path containment (Zip-Slip defence, C-2) ------------------------- *)
let path_combine (a : string) (b : string) : string =
  if String.length b > 0 && b.[0] = '/' then b
  else if a = "" then b
  else if a.[String.length a - 1] = '/' then a ^ b
  else a ^ "/" ^ b

let normalize (path : string) : string =
  let path =
    if Filename.is_relative path then Filename.concat (Sys.getcwd ()) path
    else path
  in
  let parts = String.split_on_char '/' path in
  let rec go acc = function
    | [] -> List.rev acc
    | "" :: rest | "." :: rest -> go acc rest
    | ".." :: rest -> (
        match acc with _ :: tl -> go tl rest | [] -> go acc rest)
    | seg :: rest -> go (seg :: acc) rest
  in
  "/" ^ String.concat "/" (go [] parts)

(** Resolve [rel] under [out_dir]; None if it escapes (absolute / traversal). *)
let safe_join (out_dir : string) (rel : string) : string option =
  let root = normalize out_dir in
  match try Some (normalize (path_combine root rel)) with _ -> None with
  | None -> None
  | Some full ->
      let root_sep =
        if String.length root > 0 && root.[String.length root - 1] = '/' then
          root
        else root ^ "/"
      in
      let rl = String.length root_sep in
      if
        full = root
        || (String.length full >= rl && String.sub full 0 rl = root_sep)
      then Some full
      else None

let to_local (rel : string) : string =
  String.map (fun c -> if c = '\\' then '/' else c) rel

(* error -> string (human-readable variant name) *)
let rgssad_err_str = function
  | Rgssad_core.ShortHeader -> "ShortHeader"
  | Rgssad_core.BadMagic -> "BadMagic"
  | Rgssad_core.BadVersion b -> Printf.sprintf "BadVersion %d" b
  | Rgssad_core.Truncated -> "Truncated"

let vxace_err_str = function
  | Vxace.ShortHeader -> "ShortHeader"
  | Vxace.BadMagic -> "BadMagic"
  | Vxace.BadVersion b -> Printf.sprintf "BadVersion %d" b
  | Vxace.Truncated -> "Truncated"

(* ---- VX Ace real extraction ------------------------------------------ *)
let extract_vxace_archive (archive_bytes : bytes) (d_rel : string)
    (d_abs : string) (cfg : config) (summary : Types.run_summary ref) : unit =
  match Vxace.parse archive_bytes with
  | Error e ->
      let msg = vxace_err_str e in
      summary := Types.tally (Types.Failed (d_rel, msg)) !summary;
      cfg.on_event (Log.Failed (d_abs, msg))
  | Ok entries ->
      let failed_here = ref false in
      List.iter
        (fun (e : Vxace.entry) ->
          try
            let cipher = Vxace.read_entry archive_bytes e in
            let plain = Vxace.decrypt_payload e cipher in
            let output_rel = to_local e.Vxace.name in
            match safe_join cfg.out_dir output_rel with
            | None ->
                failed_here := true;
                let why =
                  Printf.sprintf "unsafe entry path blocked (traversal): %s"
                    e.Vxace.name
                in
                summary :=
                  Types.tally (Types.Failed (e.Vxace.name, why)) !summary;
                cfg.on_event (Log.Failed (d_abs, why))
            | Some output_path ->
                if not cfg.dry_run then begin
                  let dir = Filename.dirname output_path in
                  if dir <> "" && not (Sys.file_exists dir) then mkdir_p dir;
                  Io.write_file output_path plain
                end;
                summary :=
                  Types.tally
                    (Types.Decrypted
                       ( output_rel,
                         Int64.of_int (Bytes.length plain),
                         Types.VXAce ))
                    !summary;
                cfg.on_event (Log.Decrypt (d_abs, output_path, "VXAce"))
          with ex ->
            failed_here := true;
            summary :=
              Types.tally
                (Types.Failed
                   ( e.Vxace.name,
                     Printf.sprintf "decode error: %s" (Printexc.to_string ex)
                   ))
                !summary;
            cfg.on_event
              (Log.Failed
                 (d_abs, Printf.sprintf "decode error on %s" e.Vxace.name)))
        entries;
      if not !failed_here then begin
        let manifest_path =
          Filename.concat cfg.out_dir (d_rel ^ ".entries.txt")
        in
        (if not cfg.dry_run then
           let txt =
             entries
             |> List.map (fun (e : Vxace.entry) ->
                 Printf.sprintf "%d\t%s\toffset=%d\tsize=%d" e.Vxace.index
                   e.Vxace.name e.Vxace.offset e.Vxace.size)
             |> String.concat "\n"
           in
           write_all_bytes manifest_path (Bytes.of_string txt));
        summary :=
          Types.tally
            (Types.PassedThrough (manifest_path, Types.VXAce))
            !summary;
        cfg.on_event (Log.Decrypt (d_abs, manifest_path, "VXAce"))
      end

(* write a TOC manifest for an XP/VX archive (entries are Rgssad_core.entry) *)
let write_rgssad_manifest (cfg : config) (d : Types.detected_file)
    (entries : Rgssad_core.entry list) (fmt : Types.format)
    (summary : Types.run_summary ref) : unit =
  let manifest_path =
    Filename.concat cfg.out_dir (d.Types.rel_path ^ ".entries.txt")
  in
  (if not cfg.dry_run then
     let txt =
       entries
       |> List.map (fun (e : Rgssad_core.entry) ->
           Printf.sprintf "%d\t%s\toffset=%d\tsize=%d" e.Rgssad_core.index
             e.Rgssad_core.name e.Rgssad_core.offset e.Rgssad_core.size)
       |> String.concat "\n"
     in
     write_all_bytes manifest_path (Bytes.of_string txt));
  summary := Types.tally (Types.PassedThrough (manifest_path, fmt)) !summary;
  cfg.on_event
    (Log.Decrypt (d.Types.abs_path, manifest_path, Types.format_to_string fmt))

let run (cfg : config) : Types.run_summary =
  let summary = ref (Types.run_summary_empty (Unix.gettimeofday ())) in
  cfg.on_event (Log.KeyFound cfg.key_source);
  let detected = Walk.walk cfg.game_dir in
  summary :=
    {
      !summary with
      Types.inputs_scanned = List.length detected;
      key_source = cfg.key_source;
    };
  List.iter
    (fun (d : Types.detected_file) ->
      cfg.on_event (Log.Walked (d.Types.abs_path, d.Types.size_bytes));
      cfg.on_event
        (Log.Detected (d.Types.abs_path, Types.format_to_string d.Types.format));
      let out_rel = d.Types.rel_path in
      let out_abs = path_combine cfg.out_dir out_rel in
      match d.Types.format with
      | Types.MV -> (
          match Dispatch.decrypt_single cfg.key d.Types.abs_path with
          | Ok (bytes, kind, was) ->
              if was then begin
                let real_kind_out = rename_by_kind out_rel kind in
                let real_out_abs = path_combine cfg.out_dir real_kind_out in
                if not cfg.dry_run then write_all_bytes real_out_abs bytes;
                summary :=
                  Types.tally
                    (Types.Decrypted
                       ( real_kind_out,
                         Int64.of_int (Bytes.length bytes),
                         Types.MV ))
                    !summary;
                cfg.on_event
                  (Log.Decrypt (d.Types.abs_path, real_out_abs, "MV"))
              end
              else begin
                if not cfg.dry_run then copy_through d.Types.abs_path out_abs;
                summary :=
                  Types.tally (Types.PassedThrough (out_rel, Types.MV)) !summary;
                cfg.on_event (Log.PassThrough d.Types.abs_path)
              end
          | Error msg ->
              let broken = out_abs ^ ".broken" in
              if not cfg.dry_run then write_all_bytes broken (Bytes.create 0);
              summary :=
                Types.tally (Types.Failed (d.Types.rel_path, msg)) !summary;
              cfg.on_event (Log.Failed (d.Types.abs_path, msg)))
      | Types.MZ -> (
          match Dispatch.decrypt_archive cfg.key d.Types.abs_path with
          | Ok entries ->
              let dir_part = Filename.dirname out_rel in
              let safe_dir =
                if dir_part = "" || dir_part = "." then "." else dir_part
              in
              List.iter
                (fun (entry_name, bytes, kind) ->
                  (* I-5: renameByKind takes (relPath, kind) — order matters *)
                  let entry_out_rel =
                    rename_by_kind (path_combine safe_dir entry_name) kind
                  in
                  match safe_join cfg.out_dir entry_out_rel with
                  | None ->
                      let why =
                        Printf.sprintf
                          "unsafe entry path blocked (traversal): %s" entry_name
                      in
                      summary :=
                        Types.tally
                          (Types.Failed (d.Types.rel_path, why))
                          !summary;
                      cfg.on_event (Log.Failed (d.Types.abs_path, why))
                  | Some entry_out_abs ->
                      if not cfg.dry_run then
                        write_all_bytes entry_out_abs bytes;
                      summary :=
                        Types.tally
                          (Types.Decrypted
                             ( entry_out_rel,
                               Int64.of_int (Bytes.length bytes),
                               Types.MZ ))
                          !summary;
                      cfg.on_event
                        (Log.Decrypt (d.Types.abs_path, entry_out_abs, "MZ")))
                entries
          | Error msg ->
              summary :=
                Types.tally (Types.Failed (d.Types.rel_path, msg)) !summary;
              cfg.on_event (Log.Failed (d.Types.abs_path, msg)))
      | Types.XP -> (
          match Xp.parse_file d.Types.abs_path with
          | Ok (entries, _) ->
              write_rgssad_manifest cfg d entries Types.XP summary
          | Error e ->
              let msg = rgssad_err_str e in
              summary :=
                Types.tally (Types.Failed (d.Types.rel_path, msg)) !summary;
              cfg.on_event (Log.Failed (d.Types.abs_path, msg)))
      | Types.VX -> (
          match Vx.parse_file d.Types.abs_path with
          | Ok (entries, _) ->
              write_rgssad_manifest cfg d entries Types.VX summary
          | Error e ->
              let msg = rgssad_err_str e in
              summary :=
                Types.tally (Types.Failed (d.Types.rel_path, msg)) !summary;
              cfg.on_event (Log.Failed (d.Types.abs_path, msg)))
      | Types.VXAce ->
          let archive_bytes = ref (Bytes.create 0) in
          let io_failed = ref false in
          (try archive_bytes := Io.read_file d.Types.abs_path
           with e ->
             io_failed := true;
             let msg =
               Printf.sprintf "I/O during open: %s" (Printexc.to_string e)
             in
             summary :=
               Types.tally (Types.Failed (d.Types.rel_path, msg)) !summary;
             cfg.on_event (Log.Failed (d.Types.abs_path, msg)));
          if (not !io_failed) && Bytes.length !archive_bytes <> 0 then
            extract_vxace_archive !archive_bytes d.Types.rel_path
              d.Types.abs_path cfg summary)
    detected;
  summary := { !summary with Types.finished_at = Unix.gettimeofday () };
  !summary
