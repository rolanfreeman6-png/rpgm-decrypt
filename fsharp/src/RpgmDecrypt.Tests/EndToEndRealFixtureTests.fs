module RpgmDecrypt.Tests.EndToEndRealFixtureTests

open RpgmDecrypt.Core
open RpgmDecrypt.Tests
open System.IO
// Generator bindings — qualified to avoid F# `open` resolution ambiguity
// when a module file uses long-form `namespace ... module ... =` syntax.
let private syntheticKey =
    RpgmDecrypt.Tests.Generator.syntheticKey
let private fakePngHeader =
    RpgmDecrypt.Tests.Generator.fakePngHeader
let private pad16 =
    RpgmDecrypt.Tests.Generator.pad16
let private buildSyntheticMvGame =
    RpgmDecrypt.Tests.Generator.buildSyntheticMvGame
let private buildSyntheticMzPak =
    RpgmDecrypt.Tests.Generator.buildSyntheticMzPak
let private buildSyntheticXpRgssad =
    RpgmDecrypt.Tests.Generator.buildSyntheticXpRgssad

let private tmpPath () : string =
    Path.Combine(Path.GetTempPath(),
                 "rpgm-decrypt-tests-real-" +
                 System.Guid.NewGuid().ToString("N").Substring(0, 8))

let testMvFullPipeline () =
    Test.register "End-to-end: synthetic MV game -> decrypted mirror-tree exact" (fun () ->
        let tmpRoot = tmpPath ()
        try
            let gameDir = Path.Combine(tmpRoot, "game")
            buildSyntheticMvGame gameDir
            let outDir  = Path.Combine(tmpRoot, "out")
            let summary =
                Report.run
                    { GameDir   = gameDir
                      OutDir    = outDir
                      Key       = syntheticKey
                      KeySource = "test fixture (DEADBEEF...)"
                      DryRun    = false
                      OnEvent   = fun _ -> () }
            Test.isTrue "InputsScanned >= 7" (summary.InputsScanned >= 7)
            Test.equal
                "decrypted + passthrough + skipped + failed == scanned"
                (summary.DecryptedCount + summary.PassedThroughCount + summary.SkippedCount + summary.FailedCount)
                summary.InputsScanned
            Test.equal "FailedCount = 0" 0 summary.FailedCount
            let expectedTargets =
                [ "www/img/Characters/$Hero.png"
                  "www/img/Tilesets/Outside.png"
                  "www/img/Faces/Face1.png"
                  "www/audio/BGM/Theme1.ogg" ]
            for target in expectedTargets do
                let path = Path.Combine(outDir, target)
                Test.isTrue (sprintf "existence of %s" target) (File.Exists path)
                let actualBytes = File.ReadAllBytes path
                let kind = System.IO.Path.GetExtension target
                let isPlaintext =
                    if kind = ".png" then
                        actualBytes.Length >= 8
                        && actualBytes.[0] = byte 0x89
                        && actualBytes.[1] = byte 0x50
                        && actualBytes.[2] = byte 0x4E
                        && actualBytes.[3] = byte 0x47
                    else
                        actualBytes.Length >= 4
                        && System.Text.Encoding.ASCII.GetString(actualBytes, 0, 4) = "OggS"
                Test.isTrue (sprintf "%s decoded plaintext-magic" target) isPlaintext
        finally
            try Directory.Delete(tmpRoot, true) with | _ -> ())

let testMzPakRoundTrip () =
    Test.register "End-to-end: synthetic MZ .pak -> decryptAll yields 1 PNG byte-exact" (fun () ->
        let tmpRoot = tmpPath ()
        Directory.CreateDirectory tmpRoot |> ignore
        try
            let pngPlain = pad16 fakePngHeader
            let cipher = Crypto.xorTransform syntheticKey pngPlain
            let pakPath = Path.Combine(tmpRoot, "p.pak")
            buildSyntheticMzPak pakPath cipher
            let openResult = Mz.openPak pakPath
            match openResult with
            | Error e -> Test.isFalse (sprintf "openPak should succeed, got %A" e) true
            | Ok z ->
                let allResult = Mz.decryptAll syntheticKey z
                match allResult with
                | Error e -> Test.isFalse (sprintf "decryptAll should succeed, got %A" e) true
                | Ok entries ->
                    if List.length entries <> 1 then
                        Test.isFalse (sprintf "expected 1 entry, got %d" (List.length entries)) true
                    else
                        let entry = List.head entries
                        Test.equal "entry name" "www/img/test.png" entry.EntryName
                        Test.equalBytes "decrypted bytes match synthetic plaintext" pngPlain entry.Bytes
                        Test.equal "kind=png" "png" entry.PlaintextKind
        finally
            try Directory.Delete(tmpRoot, true) with | _ -> ())

let testXpRgssadRoundTrip () =
    Test.register "End-to-end: synthetic XP .rgssad -> parse yields 1 entry with real layout" (fun () ->
        let tmpRoot = tmpPath ()
        Directory.CreateDirectory tmpRoot |> ignore
        try
            let payload =
                System.Convert.FromHexString
                    ("785DA34BCEFC63B80C82A52AEBA08F785DA34BCEFC63B80C" +
                     "0000000100010000789C636060606000000003000100010020")
            let rgssadPath = Path.Combine(tmpRoot, "Game.rgssad")
            buildSyntheticXpRgssad rgssadPath "Graphics/Hero.rxdata" payload
            match Xp.parseFile rgssadPath with
            | Error e -> Test.isFalse (sprintf "expected Ok, got %A" e) true
            | Ok(entries, _) ->
                Test.equal "1 entry parsed" 1 (List.length entries)
                let entry = List.head entries
                Test.equal "name matches" "Graphics/Hero.rxdata" entry.Name
                Test.equal "size matches" payload.Length entry.Size
                let bytes = File.ReadAllBytes rgssadPath
                let readBack = Xp.readEntry bytes entry
                Test.equalBytes "payload round-trip" payload readBack
        finally
            try Directory.Delete(tmpRoot, true) with | _ -> ())

/// Regression: Dispatch.classify must accept PLAINTEXT .png/.ogg/.m4a (no
/// underscore) and yield Format.MV, otherwise Report.run copies nothing for
/// pass-through files. Found on 2026-06-27 against synthetic encrypted-mv
/// fixture where Balloon.png (plain PNG) was silently dropped.
let testPlaintextExtensionsClassifiedAsMV () =
    Test.register "Dispatch.classify: plaintext .png is MV (pass-through path)" (fun () ->
        let tmpRoot = tmpPath ()
        Directory.CreateDirectory tmpRoot |> ignore
        try
            let pngPath = Path.Combine(tmpRoot, "img", "Balloon.png")
            Directory.CreateDirectory(Path.Combine(tmpRoot, "img")) |> ignore
            File.WriteAllBytes(pngPath,
                System.Convert.FromHexString "89504E470D0A1A0A0000000D49484452")
            let out = Path.Combine(tmpRoot, "out")
            let summary =
                Report.run
                    { GameDir   = tmpRoot
                      OutDir    = out
                      Key       = System.Convert.FromHexString "00000000000000000000000000000000"
                      KeySource = "synthetic-all-zeros"
                      DryRun    = false
                      OnEvent   = fun _ -> () }
            Test.isTrue "scanned >= 1" (summary.InputsScanned >= 1)
            let copied = Path.Combine(out, "img", "Balloon.png")
            Test.isTrue (sprintf "pass-through PNG copied to %s" copied) (File.Exists copied)
            let actual = File.ReadAllBytes copied
            Test.equalBytes "bytes preserved" (File.ReadAllBytes pngPath) actual
        finally
            try Directory.Delete(tmpRoot, true) with | _ -> ())

let testDryRun () =
    Test.register "End-to-end: --dry-run writes no file" (fun () ->
        let tmpRoot = tmpPath ()
        try
            let gameDir = Path.Combine(tmpRoot, "game")
            buildSyntheticMvGame gameDir
            let outDir  = Path.Combine(tmpRoot, "out")
            let summary =
                Report.run
                    { GameDir   = gameDir
                      OutDir    = outDir
                      Key       = syntheticKey
                      KeySource = "test fixture"
                      DryRun    = true
                      OnEvent   = fun _ -> () }
            Test.isTrue "scanned > 0" (summary.InputsScanned > 0)
            Test.isFalse "out dir must not exist for dry-run" (Directory.Exists outDir)
        finally
            try Directory.Delete(tmpRoot, true) with | _ -> ())

let register () : unit =
    testMvFullPipeline ()
    testMzPakRoundTrip ()
    testXpRgssadRoundTrip ()
    testPlaintextExtensionsClassifiedAsMV ()
    testDryRun ()
