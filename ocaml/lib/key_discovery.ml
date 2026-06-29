(* Find the MV/MZ key without user input, plus wordlist validation against a
   real cipher. Uses yojson (System.json) and re (rpg_core.js literal scan).
   We never evaluate JavaScript. *)

type key_result = Found of bytes * string | NotFound of string

(* ---- regexes for the key literal scan -------------------------------- *)
let re1 =
  Re.Pcre.re ~flags:[ `CASELESS ]
    {|Decrypter\._encryptionKey\s*=\s*\["\\x"\s*,\s*"([0-9a-fA-F]{32})"|}
  |> Re.compile

let re2 =
  Re.Pcre.re ~flags:[ `CASELESS ] {|encryptionKey\s*=\s*"([0-9a-fA-F]{32})"|}
  |> Re.compile

let try_read_json_key (json_text : string) : string option =
  try
    match Yojson.Safe.from_string json_text with
    | `Assoc fields -> (
        match List.assoc_opt "encryptionKey" fields with
        | Some (`String v) -> Some v
        | _ -> None)
    | _ -> None
  with _ -> None

let try_system_json (path : string) : key_result =
  if not (Sys.file_exists path) then
    NotFound (Printf.sprintf "no System.json at %s" path)
  else
    try
      let txt = Bytes.to_string (Io.read_file path) in
      match try_read_json_key txt with
      | Some hex ->
          Found
            (Crypto.decode_hex_key hex, Printf.sprintf "System.json (%s)" path)
      | None ->
          NotFound
            (Printf.sprintf "System.json at %s has no .encryptionKey" path)
    with e ->
      NotFound
        (Printf.sprintf "System.json read/parse error: %s"
           (Printexc.to_string e))

let try_js_scan (path : string) : key_result =
  if not (Sys.file_exists path) then
    NotFound (Printf.sprintf "no file at %s" path)
  else
    try
      let txt = Bytes.to_string (Io.read_file path) in
      match Re.exec_opt re1 txt with
      | Some g ->
          Found
            ( Crypto.decode_hex_key (Re.Group.get g 1),
              Printf.sprintf "regex match in %s" path )
      | None -> (
          match Re.exec_opt re2 txt with
          | Some g ->
              Found
                ( Crypto.decode_hex_key (Re.Group.get g 1),
                  Printf.sprintf "regex match (encryptionKey=) in %s" path )
          | None -> NotFound (Printf.sprintf "no hex key literal in %s" path))
    with e ->
      NotFound (Printf.sprintf "js scan error: %s" (Printexc.to_string e))

let is_found = function Found _ -> true | _ -> false

(* *.js directly in [dir] (one level). *)
let js_in_dir (dir : string) : string list =
  if Sys.file_exists dir && try Sys.is_directory dir with _ -> false then
    Sys.readdir dir |> Array.to_list
    |> List.filter (fun n ->
        Filename.check_suffix (String.lowercase_ascii n) ".js")
    |> List.map (Filename.concat dir)
  else []

(* *.js anywhere under [dir]. *)
let rec js_recursive (dir : string) : string list =
  if Sys.file_exists dir && try Sys.is_directory dir with _ -> false then
    Sys.readdir dir |> Array.to_list
    |> List.concat_map (fun n ->
        let p = Filename.concat dir n in
        if try Sys.is_directory p with _ -> false then js_recursive p
        else if Filename.check_suffix (String.lowercase_ascii n) ".js" then
          [ p ]
        else [])
  else []

(** Full priority order: www/js/System.json -> www/data/System.json ->
    www/js/rpg_core.js -> sweep www/js -> sweep all of www. *)
let discover (game_dir : string) : key_result =
  let www_root = Filename.concat game_dir "www" in
  let www_js = Filename.concat www_root "js" in
  let www_js_system = Filename.concat www_js "System.json" in
  let www_rpg_core = Filename.concat www_js "rpg_core.js" in
  let www_data_sys =
    Filename.concat (Filename.concat www_root "data") "System.json"
  in
  match try_system_json www_js_system with
  | Found _ as r -> r
  | NotFound _ -> (
      match try_system_json www_data_sys with
      | Found _ as r -> r
      | NotFound _ -> (
          match try_js_scan www_rpg_core with
          | Found _ as r -> r
          | NotFound _ ->
              if not (Sys.file_exists www_root) then
                NotFound "no www/ directory in game_dir"
              else begin
                let found =
                  ref (NotFound "no encryption key found in www/js or www/data")
                in
                List.iter
                  (fun f ->
                    match try_js_scan f with
                    | Found _ as r -> found := r
                    | NotFound _ -> ())
                  (js_in_dir www_js);
                if not (is_found !found) then
                  List.iter
                    (fun f ->
                      match try_js_scan f with
                      | Found _ as r -> found := r
                      | NotFound _ -> ())
                    (js_recursive www_root);
                !found
              end))

(* First reasonable encrypted asset to validate a candidate key against. *)
let first_encrypted_sample (game_dir : string) : bytes option =
  let exts = [ ".png_"; ".ogg_"; ".m4a_"; ".rpgmvp"; ".rpgmvo"; ".rpgmvm" ] in
  let rec find_in dir =
    if not (Sys.file_exists dir && try Sys.is_directory dir with _ -> false)
    then None
    else begin
      let names = try Array.to_list (Sys.readdir dir) with _ -> [] in
      let here =
        List.filter
          (fun n ->
            let p = Filename.concat dir n in
            (try not (Sys.is_directory p) with _ -> false)
            && List.mem (String.lowercase_ascii (Filename.extension p)) exts)
          names
      in
      match here with
      | n :: _ -> (
          let p = Filename.concat dir n in
          try
            let raw = Io.read_file p in
            if Bytes.length raw >= 16 then Some (Bytes.sub raw 0 16) else None
          with _ -> None)
      | [] ->
          List.fold_left
            (fun acc n ->
              match acc with
              | Some _ -> acc
              | None ->
                  let p = Filename.concat dir n in
                  if try Sys.is_directory p with _ -> false then find_in p
                  else None)
            None names
    end
  in
  let candidates =
    [
      Filename.concat (Filename.concat game_dir "www") "img";
      Filename.concat (Filename.concat game_dir "www") "audio";
      game_dir;
    ]
  in
  List.fold_left
    (fun acc d -> match acc with Some _ -> acc | None -> find_in d)
    None candidates

(** Try each 32-char hex candidate against the first encrypted asset. *)
let discover_with_wordlist (game_dir : string) (wordlist : string array) :
    key_result =
  if Array.length wordlist = 0 then NotFound "wordlist is empty"
  else
    match first_encrypted_sample game_dir with
    | None -> NotFound "no encrypted asset to validate wordlist against"
    | Some sample ->
        let answer = ref (NotFound "no candidate in wordlist matched") in
        Array.iter
          (fun raw ->
            match !answer with
            | Found _ -> ()
            | _ -> (
                let trimmed = String.trim raw in
                if String.length trimmed = 32 then
                  try
                    let k = Crypto.decode_hex_key trimmed in
                    let t = Crypto.xor_transform k sample in
                    if Crypto.looks_like_plaintext t then
                      answer :=
                        Found
                          ( k,
                            Printf.sprintf
                              "--password-file candidate '%s' (validated \
                               against cipher sample)"
                              trimmed )
                  with _ -> ()))
          wordlist;
        !answer
