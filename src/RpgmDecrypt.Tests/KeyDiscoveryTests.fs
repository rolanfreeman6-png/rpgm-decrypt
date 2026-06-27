module RpgmDecrypt.Tests.KeyDiscoveryTests

open System.IO
open RpgmDecrypt.Core
open RpgmDecrypt.Tests.TestFramework

let register () : unit =
    Test.register "KeyDiscovery.discover finds key in synthetic System.json" (fun () ->
        let tmp = Path.Combine(Path.GetTempPath(), "rpgm-decrypt-tests-keydisc")
        if Directory.Exists tmp then Directory.Delete(tmp, true)
        try
            Directory.CreateDirectory(Path.Combine(tmp, "www", "js")) |> ignore
            let systemJson = Path.Combine(tmp, "www", "js", "System.json")
            let hex = "deadbeef00112233445566778899aabb"
            File.WriteAllText(systemJson, sprintf """{ "encryptionKey": "%s" }""" hex)
            match KeyDiscovery.discover tmp with
            | KeyDiscovery.Found(bytes, src) ->
                Test.equal "DE" (byte 0xDE) bytes.[0]
                Test.equal "AD" (byte 0xAD) bytes.[1]
                Test.equal "EF" (byte 0xEF) bytes.[3]
                Test.isTrue "source contains System.json" (src.Contains "System.json")
            | KeyDiscovery.NotFound why ->
                Test.isFalse (sprintf "expected found, got: %s" why) true
        finally
            try Directory.Delete(tmp, true) with | _ -> ())

    Test.register "KeyDiscovery.discoverWithWordlist validates first matching key" (fun () ->
        let tmp = Path.Combine(Path.GetTempPath(), "rpgm-decrypt-tests-wordlist")
        if Directory.Exists tmp then Directory.Delete(tmp, true)
        try
            let gameDir = Path.Combine(tmp, "game")
            Directory.CreateDirectory(Path.Combine(gameDir, "www", "js")) |> ignore
            Directory.CreateDirectory(Path.Combine(gameDir, "www", "img")) |> ignore
            // System.json has the real key in plaintext; cipher is XOR'd with it.
            let realHex = "deadbeef00112233445566778899aabb"
            File.WriteAllText(Path.Combine(gameDir, "www", "js", "System.json"),
                              sprintf """{ "encryptionKey": "%s" }""" realHex)
            let realKey = Crypto.decodeHexKey realHex
            let pngPlain = System.Convert.FromHexString "89504E470D0A1A0A0000000D49484452"
            let cipher = Crypto.xorTransform realKey pngPlain
            File.WriteAllBytes(Path.Combine(gameDir, "www", "img", "Hero.png_"), cipher)
            // Wordlist with the correct key LAST, plus two decoys.
            let wordlist =
                [|
                    "00000000000000000000000000000000"
                    "11111111111111111111111111111111"
                    realHex
                |]
            match KeyDiscovery.discoverWithWordlist gameDir wordlist with
            | KeyDiscovery.Found(bytes, _) ->
                Test.equalBytes "correct key bytes" realKey bytes
            | KeyDiscovery.NotFound why ->
                Test.isFalse (sprintf "expected found, got: %s" why) true
        finally
            try Directory.Delete(tmp, true) with | _ -> ())

    Test.register "KeyDiscovery.discoverWithWordlist rejects empty wordlist" (fun () ->
        match KeyDiscovery.discoverWithWordlist "C:\\nonexistent" [||] with
        | KeyDiscovery.NotFound _ -> Test.isTrue "got NotFound" true
        | _ -> Test.isFalse "expected NotFound" true)

