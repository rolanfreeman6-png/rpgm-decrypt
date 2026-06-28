(* Port of Walk.fs — recursive directory walker yielding detected_file records.
   (walkWithProgress from the F# version was dead code and is not ported.) *)

let candidate_extensions =
  [ ".rgssad"; ".rgss2a"; ".rgss3a"
  ; ".png_"; ".ogg_"; ".m4a_"
  ; ".rpgmvp"; ".rpgmvo"; ".rpgmvm"
  ; ".pak"
  ; ".png"; ".ogg"; ".m4a"; ".webp"; ".jpg" ]

let has_interesting_extension (path : string) : bool =
  List.mem (String.lowercase_ascii (Filename.extension path)) candidate_extensions

let file_size (path : string) : int64 =
  In_channel.with_open_bin path In_channel.length

(* Make [path] relative to [root] (root assumed a prefix). *)
let relative_to (root : string) (path : string) : string =
  let root =
    if Filename.check_suffix root Filename.dir_sep then root
    else root ^ Filename.dir_sep
  in
  let rl = String.length root in
  if String.length path >= rl && String.sub path 0 rl = root then
    String.sub path rl (String.length path - rl)
  else path

let rec all_files (dir : string) : string list =
  match Sys.readdir dir with
  | exception _ -> []
  | names ->
      Array.to_list names
      |> List.concat_map (fun name ->
             let p = Filename.concat dir name in
             match Sys.is_directory p with
             | true -> all_files p
             | false -> [ p ]
             | exception _ -> [])

let walk (root_dir : string) : Types.detected_file list =
  if not (Sys.file_exists root_dir) then []
  else if not (Sys.is_directory root_dir) then []
  else
    all_files root_dir
    |> List.filter has_interesting_extension
    |> List.filter_map (fun path ->
           match Dispatch.classify path with
           | Some fmt ->
               Some
                 Types.
                   { abs_path = path
                   ; rel_path = relative_to root_dir path
                   ; size_bytes = file_size path
                   ; format = fmt }
           | None -> None)
