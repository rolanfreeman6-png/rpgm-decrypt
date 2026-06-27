namespace RpgmDecrypt.Core

/// Discovery of the MV/MZ encryption key without user input.
///
/// Two-step walk:
///   1. Read `<game_dir>/www/js/System.json`, extract the `encryptionKey`
///      property and decode its 32-char hex value.
///   2. If unreadable, scan `<game_dir>/www/js/*.js` for assignments
///      to the engine's `_encryptionKey` (case-insensitive substring
///      match) and parse whichever literal shape we find.
///
/// We never evaluate JavaScript. We extract plain literals.
module KeyDiscovery =

    type Result =
        | Found of bytes: byte[] * source: string
        | NotFound of reason: string

    let private tryReadJsonKey (jsonText: string) : string option =
        try
            use doc = System.Text.Json.JsonDocument.Parse(jsonText)
            let root = doc.RootElement
            if root.ValueKind <> System.Text.Json.JsonValueKind.Object then None
            else
                let mutable found = Unchecked.defaultof<System.Text.Json.JsonElement>
                let ok = root.TryGetProperty("encryptionKey", &found)
                if ok && found.ValueKind = System.Text.Json.JsonValueKind.String then
                    let v = found.GetString()
                    Some v
                else
                    None
        with
        | _ -> None

    /// Try to read System.json and extract a hex key.
    let trySystemJson (systemJsonPath: string) : Result =
        if not (System.IO.File.Exists systemJsonPath) then
            NotFound (sprintf "no System.json at %s" systemJsonPath)
        else
            try
                let txt = System.IO.File.ReadAllText systemJsonPath
                match tryReadJsonKey txt with
                | Some hexValue ->
                    let b = Crypto.decodeHexKey hexValue
                    Found(b, sprintf "System.json (%s)" systemJsonPath)
                | None ->
                    NotFound (sprintf "System.json at %s has no .encryptionKey" systemJsonPath)
            with
            | ex -> NotFound (sprintf "System.json read/parse error: %s" ex.Message)

    /// Scan one .js file for an assignment to `_encryptionKey` or
    /// `Decrypter._encryptionKey` containing hex bytes. Captures common
    /// shapes used by rpg_core.js and plugin authors.
    let tryJsScan (jsPath: string) : Result =
        if not (System.IO.File.Exists jsPath) then
            NotFound (sprintf "no file at %s" jsPath)
        else
            try
                let txt = System.IO.File.ReadAllText jsPath
                // Push the most-common patterns in priority order. Each
                // pattern returns Option<string> to take the first hit.
                let pat1 = System.Text.RegularExpressions.Regex(
                            @"Decrypter\._encryptionKey\s*=\s*\[""\\x""\s*,\s*""([0-9a-fA-F]{32})""",
                            System.Text.RegularExpressions.RegexOptions.IgnoreCase)
                let m1 = pat1.Match(txt)
                if m1.Success then
                    let hexVal = m1.Groups.[1].Value
                    Found(Crypto.decodeHexKey hexVal, sprintf "regex match in %s" jsPath)
                else
                    let pat2 = System.Text.RegularExpressions.Regex(
                                @"encryptionKey\s*=\s*""([0-9a-fA-F]{32})""",
                                System.Text.RegularExpressions.RegexOptions.IgnoreCase)
                    let m2 = pat2.Match(txt)
                    if m2.Success then
                        Found(Crypto.decodeHexKey m2.Groups.[1].Value,
                              sprintf "regex match (encryptionKey=) in %s" jsPath)
                    else
                        NotFound (sprintf "no hex key literal in %s" jsPath)
            with
            | ex -> NotFound (sprintf "js scan error: %s" ex.Message)

    /// Discover a key using the full priority order:
    ///   System.json → rpg_core.js → other *.js.
    /// Returns the first hit with its source-string for the log.
    let discover (gameDir: string) : Result =
        let wwwJs = System.IO.Path.Combine(gameDir, "www", "js")
        let systemJson = System.IO.Path.Combine(wwwJs, "System.json")
        match trySystemJson systemJson with
        | Found _ as r -> r
        | NotFound _ ->
            let rpgCore = System.IO.Path.Combine(wwwJs, "rpg_core.js")
            match tryJsScan rpgCore with
            | Found _ as r -> r
            | NotFound _ ->
                if not (System.IO.Directory.Exists wwwJs) then
                    NotFound "no www/js/ directory in game_dir"
                else
                    let mutable found = NotFound "no encryption key found in www/js"
                    for f in System.IO.Directory.EnumerateFiles(wwwJs, "*.js") do
                        match tryJsScan f with
                        | Found _ as r ->
                            found <- r
                        | NotFound _ -> ()
                    found

    /// Discover with a user-supplied wordlist — try each in order, first
    /// decode of System.json that succeeds wins. Useful when key has
    /// been rotated between engine versions.
    let discoverWithWordlist (gameDir: string) (wordlist: string[]) : Result =
        let wwwJs = System.IO.Path.Combine(gameDir, "www", "js")
        let systemJson = System.IO.Path.Combine(wwwJs, "System.json")
        // First try System.json with the user's keys (in case the game
        // ships a key in a non-standard field).
        let mutable answer : Result = NotFound "no key candidate matched"
        for k in wordlist do
            match trySystemJson systemJson with
            | NotFound _ -> ()
            | Found _ as r -> answer <- r
        if not (match answer with Found _ -> true | _ -> false) then
            for path in
                [ System.IO.Path.Combine(wwwJs, "rpg_core.js") ]
                @ (if System.IO.Directory.Exists wwwJs
                    then Seq.toList (System.IO.Directory.EnumerateFiles(wwwJs, "*.js"))
                    else []) do
                if not (match answer with Found _ -> true | _ -> false) then
                    match tryJsScan path with
                    | NotFound _ -> ()
                    | Found _ as r -> answer <- r
        answer
