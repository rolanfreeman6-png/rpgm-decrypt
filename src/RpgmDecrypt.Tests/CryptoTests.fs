module RpgmDecrypt.Tests.CryptoTests

open RpgmDecrypt.Core
open RpgmDecrypt.Tests.TestFramework

let register () : unit =
    Test.register "Crypto.decodeHexKey: lowercase 32-char hex" (fun () ->
        let bytes = Crypto.decodeHexKey "0123456789abcdef0123456789abcdef"
        Test.equal "byte 0=01"  (byte 0x01) bytes.[0]
        Test.equal "byte 1=23"  (byte 0x23) bytes.[1]
        Test.equal "byte 15=ef" (byte 0xEF) bytes.[15])

    Test.register "Crypto.decodeHexKey: uppercase + trim" (fun () ->
        let bytes = Crypto.decodeHexKey "  DEADBEEF00112233445566778899AABB  "
        Test.equal "DE" (byte 0xDE) bytes.[0]
        Test.equal "AD" (byte 0xAD) bytes.[1]
        Test.equal "BE" (byte 0xBE) bytes.[2]
        Test.equal "EF" (byte 0xEF) bytes.[3])

    Test.register "Crypto.xorTransform is its own inverse" (fun () ->
        let key : byte[]  = [ 1; 2; 3; 4; 5 ] |> List.map byte |> Array.ofList
        let orig : byte[] = [ 0x42; 0x00; 0xFF; 0xAA; 0x55; 0xC3; 0x11 ] |> List.map byte |> Array.ofList
        let once  = Crypto.xorTransform key orig
        let twice = Crypto.xorTransform key once
        Test.equalBytes "round-trip equality" orig twice)

    Test.register "Crypto.xorTransform: zero key = identity" (fun () ->
        let key : byte[] = Array.zeroCreate<byte> 16
        let orig : byte[] = [ 0xAA; 0xBB; 0x00 ] |> List.map byte |> Array.ofList
        let once = Crypto.xorTransform key orig
        Test.equalBytes "identity" orig once)

    Test.register "Crypto.looksLikePlaintext: PNG/OGG/JPG detected" (fun () ->
        let png =
            System.Convert.FromHexString "89504E470D0A1A0A"
        let ogg = System.Text.Encoding.ASCII.GetBytes "OggSxxxxxxxxx"
        let jpg = [| byte 0xFF; byte 0xD8; byte 0xFF; byte 0xE0 |]
        Test.isTrue "png" (Crypto.looksLikePlaintext png)
        Test.isTrue "ogg" (Crypto.looksLikePlaintext ogg)
        Test.isTrue "jpg" (Crypto.looksLikePlaintext jpg))

    Test.register "Crypto.looksLikePlaintext: rejects RPGMV header" (fun () ->
        let hdr = System.Text.Encoding.ASCII.GetBytes "RPGMV3123456789012345"
        Test.isFalse "rpgmv" (Crypto.looksLikePlaintext hdr))
