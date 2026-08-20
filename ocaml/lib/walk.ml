(* Recursive directory walker yielding detected_file records. *)

let candidate_extensions =
  [
    ".rgssad";
    ".rgss2a";
    ".rgss3a";
    ".png_";
    ".ogg_";
    ".m4a_";
    ".rpgmvp";
    ".rpgmvo";
    ".rpgmvm";
    ".pak";
    ".png";
    ".ogg";
    ".m4a";
    ".webp";
    ".jpg";
  ]

let has_interesting_extension (path : string) : bool =
  List.mem
    (String.lowercase_ascii (Filename.extension path))
    candidate_extensions

let file_size (path : string) : int64 =
  In_channel.with_open_bin path In_channel.length

type node_kind = Directory | Regular | Other

let node_kind (path : string) : node_kind =
  try
    match (Unix.lstat path).Unix.st_kind with
    | Unix.S_DIR -> Directory
    | Unix.S_REG -> Regular
    | _ -> Other
  with _ -> Other

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
           match node_kind p with
           | Directory -> all_files p
           | Regular -> [ p ]
           | Other -> [])

let walk (root_dir : string) : Types.detected_file list =
  match node_kind root_dir with
  | Directory ->
    all_files root_dir
    |> List.filter has_interesting_extension
    |> List.filter_map (fun path ->
         match Dispatch.classify path with
         | Some fmt ->
             (match try Some (file_size path) with _ -> None with
             | None -> None
             | Some size_bytes ->
                 Some
                   Types.
                     {
                       abs_path = path;
                       rel_path = relative_to root_dir path;
                       size_bytes;
                       format = fmt;
                     })
          | None -> None)
  | Regular | Other -> []
