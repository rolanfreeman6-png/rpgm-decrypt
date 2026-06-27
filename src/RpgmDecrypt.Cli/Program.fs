module RpgmDecrypt.Cli.Program

open System
open System.IO
open RpgmDecrypt.Core

let fmtName =
    function
    | XP -> "XP"
    | VX -> "VX"
    | VXAce -> "VXAce"
    | MV -> "MV"
    | MZ -> "MZ"

let runSummaryToJson (s: RunSummary) : string =
    let perFmt =
        s.PerFormat
        |> Map.toList
        |> List.map (fun (k, v) -> sprintf "\"%s\":%d" (fmtName k) v)
        |> String.concat ","
    sprintf
        """{"scanned":%d,"decrypted":%d,"passthrough":%d,"skipped":%d,"failed":%d,"key_source":"%s","per_format":{%s}}"""
        s.InputsScanned s.DecryptedCount s.PassedThroughCount
        s.SkippedCount s.FailedCount s.KeySource perFmt

let runSummaryHuman (s: RunSummary) : string =
    let perFmtLine =
        s.PerFormat
        |> Map.toList
        |> List.map (fun (k, v) -> sprintf "%s=%d" (fmtName k) v)
        |> String.concat " "
    sprintf
        "scanned=%d decrypted=%d passthrough=%d skipped=%d failed=%d key=%s formats=[%s]"
        s.InputsScanned s.DecryptedCount s.PassedThroughCount
        s.SkippedCount s.FailedCount s.KeySource perFmtLine

/// Terminates the process with the supplied exit code. Used in lieu of
/// F#'s missing `return` keyword for early-exit paths from `main`.
let exitWith (n: int) : 'a =
    System.Environment.Exit n
    Unchecked.defaultof<'a>

let printHelp () =
    printfn "Usage: rpgm-decrypt [OPTIONS] <game_dir> [<out_dir>]"
    printfn ""
    printfn "Options:"
    printfn "  --password <hex>             32-char hex key for MV/MZ"
    printfn "  --password-file <path>       newline-separated candidate keys"
    printfn "  --log-format human|json      stderr log format (default human)"
    printfn "  --report-format human|json   final stdout report (default human)"
    printfn "  --dry-run                    walk + classify, write nothing"
    printfn "  --quiet                      no per-file progress"
    printfn "  -h, --help                   this help"
    printfn "  --version                    version + supported formats"
    printfn ""
    printfn "Exit codes:"
    printfn "  0  success"
    printfn "  1  internal error"
    printfn "  2  usage error"
    printfn "  3  I/O error"
    printfn "  4  no supported files found"
    printfn "  5  partial: some decrypted, others failed"

let printVersion () =
    printfn "rpgm-decrypt 0.1.0"
    printfn "  engine support: XP / VX / VX Ace / MV / MZ"
    printfn "  built on .NET %s" (Environment.Version.ToString())

[<EntryPoint>]
let main (argv: string[]) : int =

    // --- Parse args ---
    let mutable help    = false
    let mutable version = false
    let mutable quiet   = false
    let mutable dryRun  = false
    let mutable logFmt  = Log.Human
    let mutable repFmt  = Log.Human
    let mutable password : string = null
    let mutable passwordFile : string = null
    let pos = ResizeArray<string>()
    let err = ref 0

    let i = ref 0
    while !i < argv.Length do
        let a = argv.[!i]
        match a with
        | "-h" | "--help"               -> help <- true
        | "--version"                   -> version <- true
        | "--quiet"                     -> quiet <- true
        | "--dry-run"                   -> dryRun <- true
        | "--log-format"    when !i + 1 < argv.Length ->
            match argv.[!i + 1].ToLowerInvariant() with
            | "json"  -> logFmt <- Log.Json
            | "human" -> logFmt <- Log.Human
            | _ ->
                eprintfn "error: --log-format must be human|json"
                err := 1
            i := !i + 1
        | "--log-format"    -> err := 1
        | "--report-format" when !i + 1 < argv.Length ->
            match argv.[!i + 1].ToLowerInvariant() with
            | "json"  -> repFmt <- Log.Json
            | "human" -> repFmt <- Log.Human
            | _ ->
                eprintfn "error: --report-format must be human|json"
                err := 1
            i := !i + 1
        | "--report-format" -> err := 1
        | "--password"      when !i + 1 < argv.Length ->
            password <- argv.[!i + 1]
            i := !i + 1
        | "--password"      -> err := 1
        | "--password-file" when !i + 1 < argv.Length ->
            passwordFile <- argv.[!i + 1]
            i := !i + 1
        | "--password-file" -> err := 1
        | _ when a.StartsWith "--" ->
            eprintfn "error: unknown option %s" a
            err := 1
        | _ -> pos.Add a
        i := !i + 1

    if version then
        printVersion ()
        exitWith !err

    if help || !err <> 0 then
        printHelp ()
        exitWith (if !err <> 0 then 2 else 0)

    if pos.Count = 0 then
        eprintfn "error: missing <game_dir>"
        exitWith 2

    let gameDir = pos.[0]
    let outDir  =
        if pos.Count >= 2 then pos.[1]
        else
            let parent = Directory.GetParent(gameDir).FullName
            let trimmed =
                gameDir.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar)
            let stem = Path.GetFileName(trimmed)
            Path.Combine(parent, "rpgm-decrypted-" + stem)

    if not (Directory.Exists gameDir) then
        eprintfn "error: game_dir not found: %s" gameDir
        exitWith 3

    // --- Resolve key ---
    let keyResult : KeyDiscovery.Result =
        match Option.ofObj password, Option.ofObj passwordFile with
        | Some p, _ ->
            try KeyDiscovery.Found(Crypto.decodeHexKey p, "--password flag")
            with ex ->
                eprintfn "error: invalid --password: %s" ex.Message
                exitWith 2
        | None, Some pf ->
            if not (File.Exists pf) then
                eprintfn "error: --password-file not found: %s" pf
                exitWith 3
            let words =
                File.ReadAllLines pf
                |> Array.filter (fun s -> not (String.IsNullOrWhiteSpace s))
            KeyDiscovery.discoverWithWordlist gameDir words
        | None, None ->
            KeyDiscovery.discover gameDir

    match keyResult with
    | KeyDiscovery.NotFound why ->
        eprintfn "error: no encryption key recovered (%s)" why
        eprintfn "       supply --password <hex32> or --password-file <list>"
        exitWith 4
    | KeyDiscovery.Found(keyBytes, src) ->
        let summary =
            Report.run
                { GameDir   = gameDir
                  OutDir    = outDir
                  Key       = keyBytes
                  KeySource = src
                  DryRun    = dryRun
                  OnEvent   = (if quiet then fun _ -> () else Log.emit logFmt) }
        Crypto.zeroFill keyBytes
        match repFmt with
        | Log.Json   -> printfn "%s" (runSummaryToJson summary)
        | Log.Human -> printfn "%s" (runSummaryHuman summary)
        // Final exit-code decision. No early return — final expression.
        if summary.InputsScanned = 0 then 4
        elif summary.FailedCount = 0 then 0
        elif summary.DecryptedCount = 0 && summary.PassedThroughCount = 0 then 5
        elif summary.FailedCount > 0 && summary.DecryptedCount > 0 then 5
        else 0
