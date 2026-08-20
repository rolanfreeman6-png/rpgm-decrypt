(* Classify by extension/magic and dispatch to the right per-format decoder. *)

let classify (abs_path : string) : Types.format option =
  if not (Sys.file_exists abs_path) then None
  else
    let read_head () =
      try
        let ic = open_in_bin abs_path in
        Fun.protect
          ~finally:(fun () -> close_in_noerr ic)
          (fun () ->
            let buf = Bytes.make 16 '\000' in
            let n = input ic buf 0 16 in
            if n < 16 then Bytes.sub buf 0 n else buf)
      with _ -> raise Exit
    in
    try
      let ext = String.lowercase_ascii (Filename.extension abs_path) in
      let first_bytes = read_head () in
    let ver_at7 () =
      if Bytes.length first_bytes >= 8 then Char.code (Bytes.get first_bytes 7)
      else -1
    in
    match ext with
    (* `.rgssad` (XP) and `.rgss2a` (VX) are the SAME RGSSAD v1 format; the
       version byte only distinguishes v1 from VX Ace's v3. Trust the version
       byte for v3 detection, else fall back to the extension's XP/VX label. *)
    | ".rgssad" -> (
        match ver_at7 () with 0x03 -> Some Types.VXAce | _ -> Some Types.XP)
    | ".rgss2a" -> (
        match ver_at7 () with 0x03 -> Some Types.VXAce | _ -> Some Types.VX)
    | ".rgss3a" -> Some Types.VXAce
    (* A `.pak` is an RPG Maker MZ archive only if it is actually a ZIP. NW.js /
       Chromium games ship engine `.pak` files (locales/*.pak, resources.pak,
       nw_*.pak) that share the extension but are NOT ZIPs — treat those as
       not-our-format (skipped) instead of a failed MZ decode. *)
    | ".pak" -> if Crypto.is_zip_magic first_bytes then Some Types.MZ else None
    | ".png_" | ".ogg_" | ".m4a_" -> Some Types.MV
    | ".rpgmvp" | ".rpgmvo" | ".rpgmvm" -> Some Types.MV
    | ".png" | ".ogg" | ".m4a" | ".webp" | ".jpg" -> Some Types.MV
    | _ ->
        if Crypto.is_rgssad_magic first_bytes && Bytes.length first_bytes >= 8
        then
          match ver_at7 () with
          | 0x03 -> Some Types.VXAce
          | _ -> Some Types.XP
        else if Crypto.is_zip_magic first_bytes then Some Types.MZ
        else if Crypto.is_mv_magic_header first_bytes then Some Types.MV
        else if Crypto.is_mz_magic_header first_bytes then Some Types.MZ
        else None
    with Exit -> None | _ -> None

(** Decrypt a single MV/MZ asset. Returns (bytes, kind, was-decrypted). *)
let decrypt_single (key : bytes) (abs_path : string) :
    (bytes * string * bool, string) result =
  try
    let bytes = Io.read_file abs_path in
    let out, kind, was =
      match Mv.decrypt key bytes with
      | Mv.Plaintext (k, b) -> (b, k, false)
      | Mv.Decrypted (k, b) -> (b, k, true)
       | Mv.Unsure _ ->
           raise
             (Invalid_argument
                "decryption did not produce a recognized media signature")
    in
    Ok (out, kind, was)
  with e -> Error (Printexc.to_string e)

(** Decrypt a packed MZ archive (.pak). Returns (name, bytes, kind) tuples. *)
let decrypt_archive (key : bytes) (abs_path : string) :
    ((string * bytes * string) list, string) result =
  match Mz.open_pak abs_path with
  | Error Mz.NotAZipFile ->
      Error (Printf.sprintf "%s: not a ZIP / .pak archive" abs_path)
  | Error (Mz.BadHeader msg) ->
      Error (Printf.sprintf "%s: bad zip header — %s" abs_path msg)
  | Error (Mz.IOFailure msg) ->
      Error (Printf.sprintf "%s: I/O — %s" abs_path msg)
  | Ok z -> (
      let r = Mz.decrypt_all key z in
      (try Zip.close_in z with _ -> ());
      match r with
      | Error msg -> Error (Printf.sprintf "%s: %s" abs_path msg)
      | Ok entries ->
          Ok
            (List.map
               (fun (e : Mz.entry_result) ->
                 (e.entry_name, e.bytes, e.plaintext_kind))
               entries))

(** Convert a `.png_` style extension given the actual kind to a real ext. *)
let choose_output_extension (input_ext : string) (kind : string) : string =
  match kind with
  | "png" -> ".png"
  | "ogg" -> ".ogg"
  | "m4a" -> ".m4a"
  | "webp" -> ".webp"
  | "jpg" -> ".jpg"
  | _ -> (
      match input_ext with
      | ".png_" -> ".png"
      | ".ogg_" -> ".ogg"
      | ".m4a_" -> ".m4a"
      | _ -> ".bin")
