module RpgmDecrypt.Tests.EndToEndTests

open System.IO
open RpgmDecrypt.Core
open RpgmDecrypt.Tests.TestFramework

let register () : unit =
    Test.register "End-to-end: MV .png_ round-trip via Report.run" (fun () ->
        let tmpRoot = Path.Combine(Path.GetTempPath(), "rpgm-decrypt-e2e")
        if Directory.Exists tmpRoot then Directory.Delete(tmpRoot, true)
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
        let mutable capturedLog = []
        let _ =
            Report.run
                { GameDir   = gameDir
                  OutDir    = outDir
                  Key       = key
                  KeySource = "test fixture"
                  DryRun    = false
                  OnEvent   = fun ev -> capturedLog <- ev :: capturedLog }
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
        Directory.Delete(tmpRoot, true))
