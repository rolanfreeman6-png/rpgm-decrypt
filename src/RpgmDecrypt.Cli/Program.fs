module RpgmDecrypt.Cli.Program

open System
open System.IO
open RpgmDecrypt.Core

let hrFmt =
    function XP -> "XP" | VX -> "VX" | VxAce -> "VxAce" | MV -> "MV" | MZ -> "MZ"

let exitWith (n: int) : 'a =
    System.Environment.Exit n
    Unchecked.defaultof<'a>

let runSummaryToJson (s: RunSummary) : string =
    let perFmt =
        s.PerFormat
        |> Map.toList
        |> List.map (fun (k, v) -> sprintf "\"%s\":%d" (hrFmt k) v)
        |> String.concat ","
    sprintf
        """{"scanned":%d,"decrypted":%d,"passthrough":%d,"skipped":%d,"failed":%d,"key_source":"%s","per_format":{%s}}"""
        s.InputsScanned s.DecryptedCount s.PassedThroughCount
        s.SkippedCount s.FailedCount s.KeySource perFmt

let runSummaryHuman (s: RunSummary) : string =
    let perFmtLine =
        s.PerFormat
        |> Map.toList
        |> List.map (fun (k, v) -> sprintf "%s=%d" (hrFmt k) v)
        |> String.concat " "
    sprintf
        "scanned=%d decrypted=%d passthrough=%d skipped=%d failed=%d key=%s formats=[%s]"
        s.InputsScanned s.DecryptedCount s.PassedThroughCount
        s.SkippedCount s.FailedCount s.KeySource perFmtLine

[<EntryPoint>]
let main (argv: string[]) : int =

    let mutable help    = false
    let mutable version = false
    let mutable quiet   = false
    let mutable dryRun  = false
    let mutable logFmt  = Log.Human
    let mutable repFmt  = Log.Human
    let mutable password : string = null
    let mutable passwordFile : string = null
    let mutable vxaceSeed : string = null
    let mutable errNum = 0
    let pos = ResizeArray<string>()

    let tryParseFlag (i: int) (name: string) (set: string -> 'a) =
        if i + 1 >= argv.Length then
            eprintfn "error: %s requires a value" name
            errNum <- errNum + 1
            false
        else
            set argv.[i + 1] |> ignore
            true

    let logFmtStrToEnum (s: string) =
        match s.ToLowerInvariant() with
        | "json"  -> logFmt <- Log.Json;   true
        | "human" -> logFmt <- Log.Human;  true
        | _ -> eprintfn "error: --log-format must be human|json"; errNum <- errNum + 1; false

    let repFmtStrToEnum (s: string) =
        match s.ToLowerInvariant() with
        | "json"  -> repFmt <- Log.Json;   true
        | "human" -> repFmt <- Log.Human;  true
        | _ -> eprintfn "error: --report-format must be human|json"; errNum <- errNum + 1; false

    let i = ref 0
    while !i < argv.Length do
        let a = argv.[!i]
        match a with
        | "-h" | "--help"     -> help <- true
        | "--version"         -> version <- true
        | "--quiet"           -> quiet <- true
        | "--dry-run"         -> dryRun <- true
        | "--log-format"      when tryParseFlag !i a logFmtStrToEnum -> i := !i + 1
        | "--log-format"      -> errNum <- errNum + 1
        | "--report-format"   when tryParseFlag !i a repFmtStrToEnum -> i := !i + 1
        | "--report-format"   -> errNum <- errNum + 1
        | "--password"        when tryParseFlag !i a (fun s -> password <- s) -> i := !i + 1
        | "--password"        -> errNum <- errNum + 1
        | "--password-file"   when tryParseFlag !i a (fun s -> passwordFile <- s) -> i := !i + 1
        | "--password-file"   -> errNum <- errNum + 1
        | "--vxace-seed"      when tryParseFlag !i a (fun s -> vxaceSeed <- s) -> i := !i + 1
        | "--vxace-seed"      -> errNum <- errNum + 1
        | _ when a.StartsWith "--" -> eprintfn "error: unknown option %s" a; errNum <- errNum + 1
        | _ -> pos.Add a
        i := !i + 1

    if version then
        printfn "rpgm-decrypt 0.2.0"
        printfn "  engine support: XP / VX / VX Ace / MV / MZ"
        printfn "  built on .NET %s" (Environment.Version.ToString())
        exitWith errNum

    if help || errNum <> 0 then
        printfn "Usage: rpgm-decrypt [OPTIONS] <game_dir> [<out_dir>]"
        printfn ""
        printfn "Options:"
        printfn "  --password <hex>             32-char hex key for MV/MZ"
        printfn "  --password-file <path>       newline-separated candidate keys"
        printfn "  --vxace-seed <8hex>          RPG Maker VX Ace master-seed (8 hex chars)"
        printfn "  --log-format human|json      stderr log format (default human)"
        printfn "  --report-format human|json   final stdout report (default human)"
        printfn "  --dry-run                    walk + classify, write nothing"
        printfn "  --quiet                      no per-file progress"
        printfn "  -h, --help                   this help"
        printfn "  --version                    version + supported formats"
        printfn ""
        printfn "Exit codes: 0=ok 1=internal 2=usage 3=io 4=no-key 5=partial"
        exitWith (if errNum <> 0 then 2 else 0)

    if pos.Count = 0 then
        eprintfn "error: missing <game_dir>"
        exitWith 2

    let gameDir = pos.[0]
    let outDir  =
        if pos.Count >= 2 then pos.[1]
        else
            let parentInfo = Directory.GetParent gameDir
            let parent = if isNull parentInfo then gameDir else parentInfo.FullName
            let trimmed = gameDir.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar)
            let stem = if String.IsNullOrEmpty trimmed then "game" else Path.GetFileName trimmed
            Path.Combine(parent, "rpgm-decrypted-" + stem)

    if not (Directory.Exists gameDir) then
        eprintfn "error: game_dir not found: %s" gameDir
        exitWith 3

    let passwordOpt = Option.ofObj password
    let passwordFileOpt = Option.ofObj passwordFile
    let vxaceSeedOpt = Option.ofObj vxaceSeed

    let keyResult : KeyDiscovery.Result =
        match passwordOpt, passwordFileOpt, vxaceSeedOpt with
        | Some p, _, _ ->
            try KeyDiscovery.Found(Crypto.decodeHexKey p, "--password flag")
            with ex -> eprintfn "error: invalid --password: %s" ex.Message; exitWith 2
        | None, Some pf, _ ->
            if not (File.Exists pf) then
                eprintfn "error: --password-file not found: %s" pf; exitWith 3
            let words = File.ReadAllLines pf |> Array.filter (fun s -> not (String.IsNullOrWhiteSpace s))
            KeyDiscovery.discoverWithWordlist gameDir words
        | None, None, Some seedHex ->
            if seedHex.Length <> 8 then
                eprintfn "error: --vxace-seed requires exactly 8 hex chars (got %d)" seedHex.Length; exitWith 2
            let seedBytes : byte[] =
                try System.Convert.FromHexString seedHex
                with ex -> eprintfn "error: --vxace-seed: invalid hex: %s" ex.Message; exitWith 2
            let masterKey =
                uint32 seedBytes.[0]
                ||| (uint32 seedBytes.[1] <<< 8)
                ||| (uint32 seedBytes.[2] <<< 16)
                ||| (uint32 seedBytes.[3] <<< 24)
            let derived = Array.zeroCreate<byte> 16
            let mutable rotatingKey = masterKey * 9u + 3u
            let safe (b: byte) = if int b < 0 then byte (256 + int b) else b
            for i in 0 .. 15 do
                derived.[i] <- safe (byte rotatingKey)
                rotatingKey <- rotatingKey * 7u + 3u
            KeyDiscovery.Found(derived, sprintf "--vxace-seed derived from master=0x%08X" masterKey)
        | None, None, None ->
            KeyDiscovery.discover gameDir

    match keyResult with
    | KeyDiscovery.NotFound why ->
        eprintfn "error: no encryption key recovered (%s)" why
        eprintfn "       supply --password <hex32>, --password-file <list>, or --vxace-seed <8hex>"
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
        | Log.Human  -> printfn "%s" (runSummaryHuman summary)
        if summary.InputsScanned = 0 then exitWith 4
        elif summary.FailedCount = 0 then exitWith 0
        elif summary.DecryptedCount = 0 && summary.PassedThroughCount = 0 then exitWith 5
        else exitWith (if summary.FailedCount > 0 && summary.DecryptedCount > 0 then 5 else 0)
