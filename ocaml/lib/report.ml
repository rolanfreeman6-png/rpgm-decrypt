(* Orchestrator: walk -> classify -> decrypt -> write a mirror tree under
   out_dir, building a run_summary. Includes the Zip-Slip containment check
   (safe_join) and the MZ argument-order fix. *)

type config = {
  game_dir : string;
  out_dir : string;
  key : bytes;
  key_available : bool;
  vxace_master_key : int option;
  key_source : string;
  dry_run : bool;
  mirror : bool;
  on_event : Log.event -> unit;
}

(* ---- filesystem helpers (mkdir -p, since OCaml's is single-level) ----- *)
let file_kind (path : string) : Unix.file_kind option =
  try Some (Unix.lstat path).Unix.st_kind with _ -> None

let is_real_directory (path : string) : bool =
  match file_kind path with Some Unix.S_DIR -> true | _ -> false

let ensure_not_symlink (path : string) : unit =
  match file_kind path with
  | Some Unix.S_LNK -> invalid_arg ("symlink output path: " ^ path)
  | _ -> ()

let rec mkdir_p (dir : string) : unit =
  if dir = "" || dir = "." || dir = "/" then ()
  else
    match file_kind dir with
    | Some Unix.S_DIR -> ()
    | Some _ -> invalid_arg ("output parent is not a directory: " ^ dir)
    | None ->
        mkdir_p (Filename.dirname dir);
        (try Unix.mkdir dir 0o755
         with Unix.Unix_error (Unix.EEXIST, _, _) ->
           if not (is_real_directory dir) then
             invalid_arg ("output parent is not a directory: " ^ dir))

let write_all_bytes (path : string) (b : bytes) : unit =
  let dir = Filename.dirname path in
  if dir <> "" && not (is_real_directory dir) then mkdir_p dir;
  ensure_not_symlink path;
  Io.write_file path b

let copy_through (src : string) (dst : string) : unit =
  let dir = Filename.dirname dst in
  if dir <> "" && not (is_real_directory dir) then mkdir_p dir;
  ensure_not_symlink dst;
  Io.write_file dst (Io.read_file src)

let rename_by_kind (rel_path : string) (kind : string) : string =
  match kind with
  | "png" | "ogg" | "m4a" | "webp" | "jpg" ->
      (* Swap whatever encrypted extension the input had (.png_, .rpgmvp, …)
         for the real one implied by the decrypted [kind]. Join with "/" (never
         Filename.concat, whose "\\" on Windows would defeat the "/"-based
         safe_join traversal check). *)
      let dir = Filename.dirname rel_path in
      let stem = Filename.remove_extension (Filename.basename rel_path) in
      let base = stem ^ "." ^ kind in
      if dir = "" || dir = "." then base else dir ^ "/" ^ base
  | _ -> rel_path

(* Map an encrypted extension to its real one by name alone (no content), for
   files that pass through undecrypted (e.g. empty placeholder assets) but must
   still be renamed so the engine finds them. Returns [None] if the extension
   is not an encrypted asset extension. *)
let rename_encrypted_ext (rel_path : string) : string option =
  let ext = String.lowercase_ascii (Filename.extension rel_path) in
  let real =
    match ext with
    | ".png_" | ".rpgmvp" -> Some "png"
    | ".ogg_" | ".rpgmvo" -> Some "ogg"
    | ".m4a_" | ".rpgmvm" -> Some "m4a"
    | _ -> None
  in
  match real with Some kind -> Some (rename_by_kind rel_path kind) | None -> None

(* ---- path containment (Zip-Slip defence, C-2) ------------------------- *)
let path_combine (a : string) (b : string) : string =
  if String.length b > 0 && b.[0] = '/' then b
  else if a = "" then b
  else if a.[String.length a - 1] = '/' then a ^ b
  else a ^ "/" ^ b

(* Windows drive-letter prefix, e.g. "C:". *)
let is_drive_abs (p : string) : bool =
  String.length p >= 2
  && (let c = Char.lowercase_ascii p.[0] in
      c >= 'a' && c <= 'z')
  && p.[1] = ':'

(* Canonicalise to an absolute, slash-separated path with "."/".." collapsed.
   Separator-agnostic (accepts both '/' and '\\') and Windows-aware: a
   drive-letter prefix ("C:") is preserved as the root instead of being pushed
   below a bogus leading "/". On POSIX (no drive, leading '/') the behaviour is
   unchanged. *)
let normalize (path : string) : string =
  let path = String.map (fun c -> if c = '\\' then '/' else c) path in
  let path =
    if is_drive_abs path || (String.length path > 0 && path.[0] = '/') then path
    else
      let cwd =
        String.map (fun c -> if c = '\\' then '/' else c) (Sys.getcwd ())
      in
      if cwd = "" then path else cwd ^ "/" ^ path
  in
  let drive, rest =
    if is_drive_abs path then
      (String.sub path 0 2, String.sub path 2 (String.length path - 2))
    else ("", path)
  in
  let parts = String.split_on_char '/' rest in
  let rec go acc = function
    | [] -> List.rev acc
    | "" :: rest | "." :: rest -> go acc rest
    | ".." :: rest -> (
        match acc with _ :: tl -> go tl rest | [] -> go acc rest)
    | seg :: rest -> go (seg :: acc) rest
  in
  let body = String.concat "/" (go [] parts) in
  if drive <> "" then drive ^ "/" ^ body else "/" ^ body

(** Resolve [rel] under [out_dir]; None if it escapes (absolute / traversal). *)
let safe_join (out_dir : string) (rel : string) : string option =
  let root = normalize out_dir in
  let rel = String.map (fun c -> if c = '\\' then '/' else c) rel in
  if
    (String.length rel > 0 && rel.[0] = '/')
    || is_drive_abs rel
  then None
  else match try Some (normalize (path_combine root rel)) with _ -> None with
  | None -> None
  | Some full ->
      let root_sep =
        if root = "/" then root
        else if String.length root > 0 && root.[String.length root - 1] = '/' then
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

(* ---- full-game mirror copy (default mode) ----------------------------- *)

(* Recursively copy every file under [src] into [dst], preserving structure.
   [skip] is a normalised absolute path (usually the out_dir) that is never
   descended into — this prevents an infinite copy when out_dir is nested
   inside game_dir. Best-effort: unreadable entries are skipped, never raise. *)
let copy_tree ~(skip : string) (src : string) (dst : string) : unit =
  let rec go (rel : string) : unit =
    let cur = if rel = "" then src else Filename.concat src rel in
    match Sys.readdir cur with
    | exception _ -> ()
    | names ->
        Array.iter
          (fun name ->
            let child_rel =
              if rel = "" then name else Filename.concat rel name
            in
            let child_abs = Filename.concat src child_rel in
            (* compare slash-normalised so a Windows "\\" can't slip past the
               out_dir guard and cause runaway copying *)
            if normalize (to_local child_abs) = skip then ()
              (* don't recurse into out_dir *)
            else
               match file_kind child_abs with
               | Some Unix.S_DIR -> go child_rel
               | Some Unix.S_REG -> (
                   try copy_through child_abs (Filename.concat dst child_rel)
                   with _ -> ())
               | Some _ | None -> ())
          names
  in
  go ""

(* Flip "hasEncryptedImages"/"hasEncryptedAudio" from true to false in a
   System.json body. Returns (new_bytes, changed). Uses a targeted regex rather
   than a full JSON round-trip so unrelated formatting/keys are left untouched. *)
let patch_system_json (b : bytes) : bytes * bool =
  let s = Bytes.to_string b in
  let flip key body =
    let re = Re.Perl.compile_pat ("(\"" ^ key ^ "\"\\s*:\\s*)true") in
    Re.replace re ~f:(fun g -> Re.Group.get g 1 ^ "false") body
  in
  let s' = flip "hasEncryptedImages" s |> flip "hasEncryptedAudio" in
  (Bytes.of_string s', s' <> s)

(* Walk the mirrored out_dir, patching every System.json so the decrypted copy
   boots without the engine trying to decrypt already-plaintext assets. *)
let strip_encryption_flags (cfg : config) : unit =
  let rec go (dir : string) : unit =
    match Sys.readdir dir with
    | exception _ -> ()
    | names ->
        Array.iter
          (fun name ->
            let p = Filename.concat dir name in
             match file_kind p with
             | Some Unix.S_DIR -> go p
             | Some Unix.S_REG ->
                 if String.lowercase_ascii name = "system.json" then begin
                  match Io.read_file p with
                  | exception _ -> ()
                  | body -> (
                      let patched, changed = patch_system_json body in
                      if changed && not cfg.dry_run then
                        try Io.write_file p patched with _ -> ())
                end
             | Some _ | None -> ())
          names
  in
  go cfg.out_dir

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
  let seed_error =
    match cfg.vxace_master_key with
    | Some expected when Bytes.length archive_bytes >= 12 ->
        let actual = Vxace_key.derive_master_key archive_bytes 8 in
        if actual = expected then None
        else
          Some
            (Printf.sprintf
               "VX Ace seed mismatch (expected master=0x%08X, archive=0x%08X)"
               expected actual)
    | _ -> None
  in
  match seed_error with
  | Some msg ->
      summary := Types.tally (Types.Failed (d_rel, msg)) !summary;
      cfg.on_event (Log.Failed (d_abs, msg))
  | None -> match Vxace.parse archive_bytes with
  | Error e ->
      let msg = vxace_err_str e in
      summary := Types.tally (Types.Failed (d_rel, msg)) !summary;
      cfg.on_event (Log.Failed (d_abs, msg))
  | Ok entries ->
      List.iter
        (fun (e : Vxace.entry) ->
          try
            let cipher = Vxace.read_entry archive_bytes e in
            let plain = Vxace.decrypt_payload e cipher in
            let output_rel = to_local e.Vxace.name in
            match safe_join cfg.out_dir output_rel with
            | None ->
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
                   if dir <> "" && not (is_real_directory dir) then mkdir_p dir;
                   ensure_not_symlink output_path;
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
        entries

(* ---- XP/VX (RGSSAD v1) real extraction -------------------------------- *)
(* Parse the RGSSAD v1 archive and write every decrypted entry into out_dir,
   mirroring the archive's internal directory tree. Entry paths are contained
   by safe_join (Zip-Slip defence). *)
let extract_rgssad_archive (archive_bytes : bytes) (d_rel : string)
    (d_abs : string) (fmt : Types.format) (cfg : config)
    (summary : Types.run_summary ref) : unit =
  match Rgssad_core.parse archive_bytes with
  | Error e ->
      let msg = rgssad_err_str e in
      summary := Types.tally (Types.Failed (d_rel, msg)) !summary;
      cfg.on_event (Log.Failed (d_abs, msg))
  | Ok (entries, _) ->
      List.iter
        (fun (e : Rgssad_core.entry) ->
          try
            let cipher = Rgssad_core.read_entry archive_bytes e in
            let plain = Rgssad_core.decrypt_data e cipher in
            let output_rel = to_local e.Rgssad_core.name in
            match safe_join cfg.out_dir output_rel with
            | None ->
                let why =
                  Printf.sprintf "unsafe entry path blocked (traversal): %s"
                    e.Rgssad_core.name
                in
                summary :=
                  Types.tally (Types.Failed (e.Rgssad_core.name, why)) !summary;
                cfg.on_event (Log.Failed (d_abs, why))
            | Some output_path ->
                if not cfg.dry_run then begin
                  let dir = Filename.dirname output_path in
                   if dir <> "" && not (is_real_directory dir) then mkdir_p dir;
                   ensure_not_symlink output_path;
                   Io.write_file output_path plain
                end;
                summary :=
                  Types.tally
                    (Types.Decrypted
                       (output_rel, Int64.of_int (Bytes.length plain), fmt))
                    !summary;
                cfg.on_event
                  (Log.Decrypt (d_abs, output_path, Types.format_to_string fmt))
          with ex ->
            summary :=
              Types.tally
                (Types.Failed
                   ( e.Rgssad_core.name,
                     Printf.sprintf "decode error: %s" (Printexc.to_string ex)
                   ))
                !summary;
            cfg.on_event
              (Log.Failed
                 (d_abs, Printf.sprintf "decode error on %s" e.Rgssad_core.name)))
        entries

let run (cfg : config) : Types.run_summary =
  if normalize (to_local cfg.game_dir) = normalize (to_local cfg.out_dir) then
    invalid_arg "game_dir and out_dir must be different";
  let summary = ref (Types.run_summary_empty (Unix.gettimeofday ())) in
  cfg.on_event (Log.KeyFound cfg.key_source);
  let detected = Walk.walk cfg.game_dir in
  summary :=
    {
      !summary with
      Types.inputs_scanned = List.length detected;
      key_source = cfg.key_source;
    };
  (* Mirror mode (default): first clone the whole game tree verbatim so every
     non-asset file (.json/.txt/.js/.exe/…) is preserved, then the decrypt loop
     below overwrites the encrypted assets in place. *)
  if cfg.mirror && not cfg.dry_run then
    copy_tree ~skip:(normalize (to_local cfg.out_dir)) cfg.game_dir cfg.out_dir;
  List.iter
    (fun (d : Types.detected_file) ->
      cfg.on_event (Log.Walked (d.Types.abs_path, d.Types.size_bytes));
      cfg.on_event
        (Log.Detected (d.Types.abs_path, Types.format_to_string d.Types.format));
      let out_rel = d.Types.rel_path in
      let out_abs = path_combine cfg.out_dir out_rel in
      match d.Types.format with
       | Types.MV ->
           if not cfg.key_available then begin
             let msg = "no MV/MZ encryption key available" in
             summary :=
               Types.tally (Types.Failed (d.Types.rel_path, msg)) !summary;
             cfg.on_event (Log.Failed (d.Types.abs_path, msg))
           end
           else begin
             match Dispatch.decrypt_single cfg.key d.Types.abs_path with
           | Ok (bytes, kind, was) ->
              if was then begin
                let real_kind_out = rename_by_kind out_rel kind in
                let real_out_abs = path_combine cfg.out_dir real_kind_out in
                if not cfg.dry_run then write_all_bytes real_out_abs bytes;
                (* In mirror mode the encrypted original was copied verbatim; if
                   decrypting renamed it (Hero.png_ -> Hero.png), drop the stale
                   twin so the engine can't pick up the encrypted file. *)
                if
                  cfg.mirror && (not cfg.dry_run) && real_kind_out <> out_rel
                  && Sys.file_exists out_abs
                then (try Sys.remove out_abs with _ -> ());
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
                (* Not decrypted (already plaintext or empty placeholder). In
                   mirror mode, if it still carries an encrypted extension
                   (.rpgmvp/.png_/…), rename it so the engine finds the asset
                   and drop the stale encrypted-named twin. *)
                let renamed =
                  if cfg.mirror then rename_encrypted_ext out_rel else None
                in
                (match renamed with
                | Some real_rel when real_rel <> out_rel ->
                    let real_abs = path_combine cfg.out_dir real_rel in
                    if not cfg.dry_run then begin
                      write_all_bytes real_abs bytes;
                      if Sys.file_exists out_abs then
                        (try Sys.remove out_abs with _ -> ())
                    end
                | _ ->
                    if not cfg.dry_run then
                      copy_through d.Types.abs_path out_abs);
                summary :=
                  Types.tally (Types.PassedThrough (out_rel, Types.MV)) !summary;
                cfg.on_event (Log.PassThrough d.Types.abs_path)
              end
           | Error msg ->
              let broken = out_abs ^ ".broken" in
              if not cfg.dry_run then write_all_bytes broken (Bytes.create 0);
              summary :=
                Types.tally (Types.Failed (d.Types.rel_path, msg)) !summary;
                cfg.on_event (Log.Failed (d.Types.abs_path, msg))
           end
       | Types.MZ ->
           if not cfg.key_available then begin
             let msg = "no MV/MZ encryption key available" in
             summary :=
               Types.tally (Types.Failed (d.Types.rel_path, msg)) !summary;
             cfg.on_event (Log.Failed (d.Types.abs_path, msg))
           end
           else begin
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
                cfg.on_event (Log.Failed (d.Types.abs_path, msg))
           end
      | (Types.XP | Types.VX) as fmt -> (
          match Io.read_file d.Types.abs_path with
          | exception e ->
              let msg =
                Printf.sprintf "I/O during open: %s" (Printexc.to_string e)
              in
              summary :=
                Types.tally (Types.Failed (d.Types.rel_path, msg)) !summary;
              cfg.on_event (Log.Failed (d.Types.abs_path, msg))
          | archive_bytes ->
              extract_rgssad_archive archive_bytes d.Types.rel_path
                d.Types.abs_path fmt cfg summary)
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
           if not !io_failed then
             if Bytes.length !archive_bytes = 0 then begin
               let msg = "Truncated" in
               summary :=
                 Types.tally (Types.Failed (d.Types.rel_path, msg)) !summary;
               cfg.on_event (Log.Failed (d.Types.abs_path, msg))
             end
             else
               extract_vxace_archive !archive_bytes d.Types.rel_path
                 d.Types.abs_path cfg summary)
    detected;
  (* Mirror mode: with the tree cloned and assets decrypted in place, clear the
     engine's "assets are encrypted" flags so the copy boots as-is. *)
   if cfg.mirror && (!summary).Types.failed_count = 0 then strip_encryption_flags cfg;
  summary := { !summary with Types.finished_at = Unix.gettimeofday () };
  !summary
