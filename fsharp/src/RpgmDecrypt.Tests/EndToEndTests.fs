module RpgmDecrypt.Tests.EndToEndTests

open System.IO
open System.IO.Compression
open RpgmDecrypt.Core
open RpgmDecrypt.Tests.TestFramework

let register () : unit =
    Test.register "End-to-end: MV .png_ round-trip via Report.run" (fun () ->
        let tmpRoot = Path.Combine(Path.GetTempPath(), "rpgm-decrypt-e2e")
        if Directory.Exists tmpRoot then Directory.Delete(tmpRoot, true)
        try
            let gameDir = Path.Combine(tmpRoot, "game")
            Directory.CreateDirectory(Path.Combine(gameDir, "www", "img")) |> ignore
            Directory.CreateDirectory(Path.Combine(gameDir, "www", "js")) |> ignore
            File.WriteAllText(Path.Combine(gameDir, "www", "js", "System.json"),
                              """{ "encryptionKey": "deadbeef00112233445566778899aabb" }""")
            let pngPlain : byte[] =
                System.Convert.FromHexString
                    "89504E470D0A1A0A0000000D49484452AABBCC"
            let key : byte[] = Crypto.decodeHexKey "deadbeef00112233445566778899aabb"
            let cipher = Crypto.xorTransform key pngPlain
            let cipherPath = Path.Combine(gameDir, "www", "img", "Hero.png_")
            File.WriteAllBytes(cipherPath, cipher)
            let outDir = Path.Combine(tmpRoot, "out")
            let _ =
                Report.run
                    { GameDir   = gameDir
                      OutDir    = outDir
                      Key       = key
                      KeySource = "test fixture"
                      DryRun    = false
                      OnEvent   = fun _ -> () }
            if not (Directory.Exists outDir) then
                Test.isFalse (sprintf "OUT DIR MISSING: %s" outDir) true
            let allFiles =
                if Directory.Exists outDir then
                    Directory.EnumerateFiles(outDir, "*", SearchOption.AllDirectories)
                    |> Seq.toList
                else []
            Test.isTrue
                (sprintf "decrypted file exists (out=%s, files=%A)" outDir allFiles)
                (File.Exists(Path.Combine(outDir, "www", "img", "Hero.png")))
            let actualBytes = File.ReadAllBytes(Path.Combine(outDir, "www", "img", "Hero.png"))
            Test.equalBytes "round-trip equality" pngPlain actualBytes
        finally
            try Directory.Delete(tmpRoot, true) with | _ -> ())

    // ---- C-2: Zip-Slip / path-traversal defence -------------------------
    Test.register "Report.safeJoin: allows nested, blocks parent-traversal" (fun () ->
        let outDir = Path.Combine(Path.GetTempPath(), "rpgm-safejoin")
        match Report.safeJoin outDir "www/img/a.png" with
        | Some _ -> Test.isTrue "nested path allowed" true
        | None   -> Test.isFalse "nested path should be allowed" true
        match Report.safeJoin outDir "../../evil.txt" with
        | None   -> Test.isTrue "parent traversal blocked" true
        | Some p -> Test.isFalse (sprintf "traversal NOT blocked: %s" p) true)

    Test.register "End-to-end: MZ .pak Zip-Slip entry is blocked, nothing escapes (C-2)" (fun () ->
        let tmpRoot =
            Path.Combine(Path.GetTempPath(),
                         "rpgm-zipslip-" + System.Guid.NewGuid().ToString("N").Substring(0, 8))
        Directory.CreateDirectory tmpRoot |> ignore
        try
            let gameDir = Path.Combine(tmpRoot, "game")
            Directory.CreateDirectory gameDir |> ignore
            let key = Crypto.decodeHexKey "deadbeef00112233445566778899aabb"
            let pngPlain = System.Convert.FromHexString "89504E470D0A1A0A0000000D49484452"
            let cipher = Crypto.xorTransform key pngPlain
            // Malicious .pak: single ZIP entry whose name escapes the out dir.
            let zipBytes =
                use ms = new MemoryStream()
                use archive = new ZipArchive(ms, ZipArchiveMode.Create, leaveOpen = true)
                let e = archive.CreateEntry "../evil.png"
                (use es = e.Open()
                 es.Write(cipher, 0, cipher.Length))
                archive.Dispose()
                ms.ToArray()
            File.WriteAllBytes(Path.Combine(gameDir, "packed.pak"), zipBytes)
            let outDir = Path.Combine(tmpRoot, "out")
            let summary =
                Report.run
                    { GameDir   = gameDir
                      OutDir    = outDir
                      Key       = key
                      KeySource = "test"
                      DryRun    = false
                      OnEvent   = fun _ -> () }
            Test.isTrue "traversal entry counted as failed" (summary.FailedCount >= 1)
            // The escape target (tmpRoot/evil.png, one level above out) must not exist.
            Test.isFalse "escaped file must NOT be written"
                (File.Exists(Path.Combine(tmpRoot, "evil.png")))
        finally
            try Directory.Delete(tmpRoot, true) with | _ -> ())

    Test.register "End-to-end: MZ .pak preserves nested entry path (I-5)" (fun () ->
        let tmpRoot =
            Path.Combine(Path.GetTempPath(),
                         "rpgm-mzpath-" + System.Guid.NewGuid().ToString("N").Substring(0, 8))
        Directory.CreateDirectory tmpRoot |> ignore
        try
            let gameDir = Path.Combine(tmpRoot, "game")
            Directory.CreateDirectory gameDir |> ignore
            let key = Crypto.decodeHexKey "deadbeef00112233445566778899aabb"
            let pngPlain = System.Convert.FromHexString "89504E470D0A1A0A0000000D49484452"
            let cipher = Crypto.xorTransform key pngPlain
            let zipBytes =
                use ms = new MemoryStream()
                use archive = new ZipArchive(ms, ZipArchiveMode.Create, leaveOpen = true)
                let e = archive.CreateEntry "www/img/test.png"
                (use es = e.Open()
                 es.Write(cipher, 0, cipher.Length))
                archive.Dispose()
                ms.ToArray()
            File.WriteAllBytes(Path.Combine(gameDir, "packed.pak"), zipBytes)
            let outDir = Path.Combine(tmpRoot, "out")
            let summary =
                Report.run
                    { GameDir   = gameDir
                      OutDir    = outDir
                      Key       = key
                      KeySource = "test"
                      DryRun    = false
                      OnEvent   = fun _ -> () }
            Test.equal "one decrypted" 1 summary.DecryptedCount
            let expected = Path.Combine(outDir, "www", "img", "test.png")
            Test.isTrue (sprintf "entry written at nested path %s" expected) (File.Exists expected)
            Test.equalBytes "bytes round-trip" pngPlain (File.ReadAllBytes expected)
        finally
            try Directory.Delete(tmpRoot, true) with | _ -> ())
