(* Port of Format.fs (module Dispatch) — classify by extension/magic and
   dispatch to the right per-format decoder. *)

let classify (abs_path : string) : Types.format option =
  if not (Sys.file_exists abs_path) then None
  else begin
    let ext = String.lowercase_ascii (Filename.extension abs_path) in
    let first_bytes =
      let ic = open_in_bin abs_path in
      let buf = Bytes.make 16 '\000' in
      let n = input ic buf 0 16 in
      close_in ic;
      if n < 16 then Bytes.sub buf 0 n else buf
    in
    let ver_at7 () =
      if Bytes.length first_bytes >= 8 then Char.code (Bytes.get first_bytes 7)
      else -1
    in
    match ext with
    | ".rgssad" ->
        if Bytes.length first_bytes < 8 then Some Types.XP
        else (
          match ver_at7 () with
          | 0x01 -> Some Types.XP
          | 0x02 -> Some Types.VX
          | 0x03 -> Some Types.VXAce
          | _ -> Some Types.XP)
    | ".rgss2a" -> Some Types.VX
    | ".rgss3a" -> Some Types.VXAce
    | ".pak" -> Some Types.MZ
    | ".png_" | ".ogg_" | ".m4a_" -> Some Types.MV
    | ".rpgmvp" | ".rpgmvo" | ".rpgmvm" -> Some Types.MV
    | ".png" | ".ogg" | ".m4a" | ".webp" | ".jpg" -> Some Types.MV
    | _ ->
        if Crypto.is_rgssad_magic first_bytes && Bytes.length first_bytes >= 8 then (
          match ver_at7 () with
          | 0x01 -> Some Types.XP
          | 0x02 -> Some Types.VX
          | 0x03 -> Some Types.VXAce
          | _ -> Some Types.XP)
        else if Crypto.is_zip_magic first_bytes then Some Types.MZ
        else if Crypto.is_mv_magic_header first_bytes then Some Types.MV
        else if Crypto.is_mz_magic_header first_bytes then Some Types.MZ
        else None
  end

(** Decrypt a single MV/MZ asset. Returns (bytes, kind, was-decrypted). *)
let decrypt_single (key : bytes) (abs_path : string) :
    (bytes * string * bool, string) result =
  try
    let bytes = Io.read_file abs_path in
    let out, kind, was =
      match Mv.decrypt key bytes with
      | Mv.Plaintext (k, b) -> (b, k, false)
      | Mv.Decrypted (k, b) -> (b, k, true)
      | Mv.Unsure b -> (b, "bin", true)
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
  | Error (Mz.IOFailure msg) -> Error (Printf.sprintf "%s: I/O — %s" abs_path msg)
  | Ok z ->
      let r = Mz.decrypt_all key z in
      (try Zip.close_in z with _ -> ());
      (match r with
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
