(* Source — MZ `.pak` extraction. The `.pak` is a plain ZIP;
   each entry's payload is individually MV-XOR-encrypted. Uses camlzip (`Zip`).
   F# read the file into a MemoryStream; camlzip reads from the path directly. *)

type entry_result = {
  entry_name : string;
  plaintext_kind : string;
  bytes : bytes;
}

type open_error = NotAZipFile | BadHeader of string | IOFailure of string

(** Open a `.pak` as a ZIP archive (checking the PK magic first, as F# did). *)
let open_pak (path : string) : (Zip.in_file, open_error) result =
  try
    let b = Io.read_file path in
    let head =
      if Bytes.length b >= 4 then Bytes.sub b 0 4
      else Bytes.sub b 0 (Bytes.length b)
    in
    if not (Crypto.is_zip_magic head) then Error NotAZipFile
    else
      begin try Ok (Zip.open_in path)
      with Zip.Error (_, _, msg) -> Error (BadHeader msg)
      end
  with
  | Sys_error msg -> Error (IOFailure msg)
  | e -> Error (IOFailure (Printexc.to_string e))

(** Iterate every entry, decrypt each with [key]. Order preserved. *)
let decrypt_all (key : bytes) (z : Zip.in_file) :
    (entry_result list, string) result =
  try
    let results =
      Zip.entries z
      |> List.filter_map (fun (e : Zip.entry) ->
          if e.Zip.is_directory then None
          else begin
            let cipher = Bytes.of_string (Zip.read_entry z e) in
            let plain, kind = Mv.decrypt_bytes key cipher in
            Some
              {
                entry_name = e.Zip.filename;
                plaintext_kind = kind;
                bytes = plain;
              }
          end)
    in
    Ok results
  with e -> Error (Printexc.to_string e)
