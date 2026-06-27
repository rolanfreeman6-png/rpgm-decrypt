namespace RpgmDecrypt.Core

/// Discovery of the MV/MZ encryption key without user input, plus the
/// `--password-file` path which tries a user-supplied wordlist against the
/// actual cipher bytes.
///
/// Strategy:
///   * `discover`              — System.json → rpg_core.js → other *.js.
///     Used when the user supplied `--password-file` is not provided, OR
///     the supplied wordlist is empty.
///   * `discoverWithWordlist`  — for each 32-char hex candidate in the
///     wordlist, attempt to validate the key by XOR-ing the first 16
///     bytes of an actual encrypted .png_/ogg_/m4a_/rpgmvp file and
///     checking whether the result looks like a real plaintext magic
///     (PNG/OGG/JPG/M4A/WebP). The first candidate that validates
///     wins; if none do, the caller is told to supply a single key via
///     `--password` instead.
///
/// We never evaluate JavaScript. We extract plain literals.
module KeyDiscovery =

    open System.IO

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
        if not (File.Exists systemJsonPath) then
            NotFound (sprintf "no System.json at %s" systemJsonPath)
        else
            try
                let txt = File.ReadAllText systemJsonPath
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
        if not (File.Exists jsPath) then
            NotFound (sprintf "no file at %s" jsPath)
        else
            try
                let txt = File.ReadAllText jsPath
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

    let private isFound = function Found _ -> true | _ -> false

    /// Discover a key using the full priority order:
    ///   * RPG Maker MV ships in two layouts:
    ///       - source / editor:    <game>/www/js/System.json
    ///       - deployed distribution: <game>/www/data/System.json
    ///     Most actual game distributions (NW.js, Steam, itch.io) use
    ///     the second layout; we try both before giving up.
    ///   * For rpg_core.js (where the engine also embeds the key):
    ///       <game>/www/js/rpg_core.js — typically stripped in deploys.
    ///       We fall through to scanning sibling *.js files.
    ///   * Then a sweep of all *.js files under both js/ and (rarely)
    ///     a Plugins folder.
    let discover (gameDir: string) : Result =
        let wwwRoot     = Path.Combine(gameDir, "www")
        let wwwJs       = Path.Combine(wwwRoot, "js")
        let wwwJsSystem = Path.Combine(wwwJs, "System.json")
        let wwwRpgCore  = Path.Combine(wwwJs, "rpg_core.js")
        let wwwDataSys  = Path.Combine(wwwRoot, "data", "System.json")

        match trySystemJson wwwJsSystem with
        | Found _ as r -> r
        | NotFound _ ->
            match trySystemJson wwwDataSys with
            | Found _ as r -> r
            | NotFound _ ->
                match tryJsScan wwwRpgCore with
                | Found _ as r -> r
                | NotFound _ ->
                    if not (Directory.Exists wwwRoot) then
                        NotFound "no www/ directory in game_dir"
                    else
                        let mutable found = NotFound "no encryption key found in www/js or www/data"
                        // Try sibling *.js in www/js.
                        if Directory.Exists wwwJs then
                            for f in Directory.EnumerateFiles(wwwJs, "*.js") do
                                match tryJsScan f with
                                | Found _ as r -> found <- r
                                | NotFound _ -> ()
                        // Final sweep: any *.js anywhere under www/ (catch
                        // unusual plugin folders shipped with some games).
                        if not (isFound found) then
                            for f in Directory.EnumerateFiles(wwwRoot, "*.js", SearchOption.AllDirectories) do
                                match tryJsScan f with
                                | Found _ as r -> found <- r
                                | NotFound _ -> ()
                        found

    /// Locate the first reasonable MV/MZ encrypted asset in `game_dir`
    /// that we can use to validate a candidate key against real cipher.
    let private firstEncryptedSample (gameDir: string) : byte[] option =
        let candidates : string list =
            [ Path.Combine(gameDir, "www", "img")
              Path.Combine(gameDir, "www", "audio")
              gameDir ]
        let mutable bytes : byte[] option = None
        let mutable idx = 0
        while idx < List.length candidates && Option.isNone bytes do
            let d = candidates.[idx]
            if Directory.Exists d then
                for ext in [| ".png_"; ".ogg_"; ".m4a_"; ".rpgmvp"; ".rpgmvo"; ".rpgmvm" |] do
                    match Directory.EnumerateFiles(d, "*" + ext, SearchOption.AllDirectories)
                          |> Seq.tryHead with
                    | Some p ->
                        try
                            let raw = File.ReadAllBytes p
                            if raw.Length >= 16 then
                                bytes <- Some raw[..15]
                                idx <- List.length candidates
                        with | _ -> ()
                    | None -> ()
            idx <- idx + 1
        bytes

    /// Try each candidate (32-char hex string, one per line in the
    /// wordlist file) against the first encrypted asset in `game_dir`.
    /// First valid candidate wins.
    let discoverWithWordlist (gameDir: string) (wordlist: string[]) : Result =
        if wordlist = [||] || Array.isEmpty wordlist then
            NotFound "wordlist is empty"
        else
            match firstEncryptedSample gameDir with
            | None ->
                NotFound "no encrypted asset to validate wordlist against"
            | Some sample ->
                let mutable answer = NotFound "no candidate in wordlist matched"
                for raw in wordlist do
                    if not (isFound answer) then
                        let trimmed = raw.Trim()
                        if trimmed.Length = 32 then
                            try
                                let candidateKey = Crypto.decodeHexKey trimmed
                                let transformed = Crypto.xorTransform candidateKey sample
                                if Crypto.looksLikePlaintext transformed then
                                    answer <-
                                        Found(candidateKey,
                                              sprintf "--password-file candidate '%s' (validated against cipher sample)" trimmed)
                            with | _ -> ()
                answer
