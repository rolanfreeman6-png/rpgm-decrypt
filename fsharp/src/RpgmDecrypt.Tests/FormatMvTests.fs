module RpgmDecrypt.Tests.FormatMvTests

open RpgmDecrypt.Core
open RpgmDecrypt.Tests.TestFramework

let knownPngHeader : byte[] =
    System.Convert.FromHexString "89504E470D0A1A0A0000000D49484452"

let keyBytes : byte[] =
    System.Convert.FromHexString "123456789ABCDEF01122334455667788"

let register () : unit =
    Test.register "Mv.decrypt: plaintext PNG is plaintext outcome" (fun () ->
        match Mv.decrypt keyBytes knownPngHeader with
        | Mv.Plaintext(kind, bytes) ->
            Test.equalBytes "PNG header match" knownPngHeader bytes
            Test.equal "kind=png" "png" kind
        | _ -> Test.isFalse "expected Plaintext outcome" true)

    Test.register "Mv.decrypt: XOR-encrypted PNG decrypts to plaintext" (fun () ->
        let cipher = Crypto.xorTransform keyBytes knownPngHeader
        Test.isFalse "cipher is not plaintext PNG" (Crypto.looksLikePlaintext cipher)
        match Mv.decrypt keyBytes cipher with
        | Mv.Decrypted(kind, plain) ->
            Test.equalBytes "decrypted bytes match" knownPngHeader plain
            Test.equal "kind=png" "png" kind
        | _ -> Test.isFalse "expected Decrypted outcome" true)

    Test.register "Mv.decrypt: wrong key produces Unsure" (fun () ->
        let cipher = Crypto.xorTransform keyBytes knownPngHeader
        let wrongKey = Array.zeroCreate<byte> 16
        match Mv.decrypt wrongKey cipher with
        | Mv.Unsure _ -> Test.isTrue "got Unsure" true
        | _ -> Test.isFalse "wrong key produced recognised plaintext" true)
