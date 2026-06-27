module RpgmDecrypt.Tests.KeyDiscoveryTests

open System.IO
open RpgmDecrypt.Core
open RpgmDecrypt.Tests.TestFramework

let register () : unit =
    Test.register "KeyDiscovery.discover finds key in synthetic System.json" (fun () ->
        let tmp = Path.Combine(Path.GetTempPath(), "rpgm-decrypt-tests-keydisc")
        if Directory.Exists tmp then Directory.Delete(tmp, true)
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
        Directory.Delete(tmp, true))
