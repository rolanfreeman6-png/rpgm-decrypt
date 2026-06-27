module RpgmDecrypt.Tests.FormatVxAceTests

open System
open RpgmDecrypt.Core
open RpgmDecrypt.Tests.TestFramework

let register () : unit =
    Test.register "VxAce.parse: real-world synthetic archive yields 1 entry" (fun () ->
        let header : byte[] =
            [| 0x52uy; 0x47uy; 0x53uy; 0x53uy; 0x41uy; 0x44uy; 0x00uy; 0x03uy |]
        let fname = System.Text.Encoding.UTF8.GetBytes "Graphics/Layer1.rvdata2"
        let magicKey = VxAce.magicKey
        let encodedName = Array.zeroCreate<byte> fname.Length
        for i = 0 to fname.Length - 1 do
            encodedName.[i] <- fname.[i] ^^^ magicKey.[i % magicKey.Length]
        // Real VxAce layout per Petschko/RPG-Maker-MV-Decrypter (MIT):
        //   size (4) || name_len (4) || name || offset (4)
        let posPayload = header.Length + 4 + 4 + fname.Length + 4
        let total = posPayload + 32  // 32 bytes of dummy payload
        let buf = Array.zeroCreate<byte> total
        Array.Copy(header, 0, buf, 0, header.Length)
        let posSize = header.Length
        buf.[posSize]     <- 32uy
        buf.[posSize + 1] <- 0uy
        buf.[posSize + 2] <- 0uy
        buf.[posSize + 3] <- 0uy
        let posNameLen = posSize + 4
        buf.[posNameLen]     <- byte fname.Length
        buf.[posNameLen + 1] <- 0uy
        buf.[posNameLen + 2] <- 0uy
        buf.[posNameLen + 3] <- 0uy
        Array.Copy(encodedName, 0, buf, posNameLen + 4, fname.Length)
        let posOffset = posNameLen + 4 + fname.Length
        buf.[posOffset]     <- byte posPayload
        buf.[posOffset + 1] <- 0uy
        buf.[posOffset + 2] <- 0uy
        buf.[posOffset + 3] <- 0uy
        match VxAce.parse buf with
        | Ok(entries, _) ->
            Test.equal "1 entry parsed" 1 (List.length entries)
            Test.equal "name matches" "Graphics/Layer1.rvdata2" entries.Head.Name
            Test.equal "size" 32 entries.Head.Size
        | Error e -> Test.isFalse (sprintf "expected Ok, got %A" e) true)

    Test.register "VxAce.parse: negative-truncated-name_len -> Truncated, no crash" (fun () ->
        // Regression test: on 2026-06-27 against F:\fr\g\HC_EP1\Game.rgss3a
        // (real RPG Maker VX Ace shipped game, 39 MB, 1914 entries) the parser
        // threw ArgumentException("count=-1110938460") because reading a real
        // uint32 name_len field cast to int32 yielded a negative value;
        // we now guard explicitly.
        let header : byte[] =
            [| 0x52uy; 0x47uy; 0x53uy; 0x53uy; 0x41uy; 0x44uy; 0x00uy; 0x03uy |]
        // First entry: size(4) + name_len(4)+ NAME_BYTES (intentionally huge) + offset(4).
        // We set name_len = 0xFFFFFFFA which overflows int to -6.
        let buf = Array.zeroCreate<byte> (header.Length + 16)
        Array.Copy(header, 0, buf, 0, header.Length)
        // size = 100
        buf.[header.Length + 0] <- 100uy
        // name_len = 0xFFFFFFFA (wraps to -6 in int)
        buf.[header.Length + 4] <- 0xFAuy
        buf.[header.Length + 5] <- 0xFFuy
        buf.[header.Length + 6] <- 0xFFuy
        buf.[header.Length + 7] <- 0xFFuy
        // (no actual name bytes — past 16 total)
        match VxAce.parse buf with
        | Error VxAce.Truncated -> Test.isTrue "got Truncated" true
        | Error e -> Test.isFalse (sprintf "expected Truncated, got %A" e) true
        | Ok _ -> Test.isFalse "expected Error not Ok" true)

    Test.register "VxAce.parse: bad magic -> BadMagic" (fun () ->
        let bad : byte[] =
            [| 0x42uy; 0x47uy; 0x53uy; 0x53uy; 0x41uy; 0x44uy; 0x00uy; 0x03uy |]
        match VxAce.parse bad with
        | Error VxAce.BadMagic -> Test.isTrue "BadMagic" true
        | _ -> Test.isFalse "expected BadMagic" true)

    Test.register "VxAce.parse: version 0x01 -> BadVersion" (fun () ->
        let v : byte[] =
            [| 0x52uy; 0x47uy; 0x53uy; 0x53uy; 0x41uy; 0x44uy; 0x00uy; 0x01uy |]
        match VxAce.parse v with
        | Error (VxAce.BadVersion b) -> Test.equal "version byte" (byte 0x01) b
        | _ -> Test.isFalse "expected BadVersion" true)
