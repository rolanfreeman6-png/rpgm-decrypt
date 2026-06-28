module RpgmDecrypt.Tests.FormatVxTests

open System
open RpgmDecrypt.Core
open RpgmDecrypt.Tests.TestFramework

let register () : unit =
    Test.register "Vx.parse: synthetic version-2 archive yields 1 entry" (fun () ->
        let header : byte[] =
            [| 0x52uy; 0x47uy; 0x53uy; 0x53uy; 0x41uy; 0x44uy; 0x00uy; 0x02uy |]
        let fname = System.Text.Encoding.UTF8.GetBytes "Graphics/Hero.png"
        let payload : byte[] = [| 0xCAuy; 0xFEuy; 0xBAuy; 0xBEuy; 0xDEuy; 0xADuy; 0xBEuy; 0xEFuy |]
        let magicKey = Vx.magicKey
        let encodedName = Array.zeroCreate<byte> fname.Length
        for i = 0 to fname.Length - 1 do
            encodedName.[i] <- fname.[i] ^^^ magicKey.[i % magicKey.Length]
        // Layout (same as XP): header | size(4) | offset(4) | name_len(4) | name
        //   | terminator (size=0 + offset=0 + name_len=0 = 12 zero bytes) | payload
        let posNameStart  = header.Length + 12
        let posTerminator = posNameStart + fname.Length
        let posPayload    = posTerminator + 12
        let total         = posPayload + payload.Length
        let buf = Array.zeroCreate<byte> total
        Array.Copy(header, 0, buf, 0, header.Length)
        buf.[header.Length]     <- byte payload.Length      // size
        buf.[header.Length + 4] <- byte posPayload          // offset
        buf.[header.Length + 8] <- byte fname.Length        // name_len
        Array.Copy(encodedName, 0, buf, posNameStart, fname.Length)
        // terminator-record is 12 zero bytes (already by Array.zeroCreate)
        Array.Copy(payload, 0, buf, posPayload, payload.Length)
        match Vx.parse buf with
        | Ok(entries, _) ->
            Test.equal "1 entry" 1 (List.length entries)
            let entry = List.head entries
            Test.equal "name" "Graphics/Hero.png" entry.Name
            Test.equal "size" payload.Length entry.Size
            Test.equal "offset" (int64 posPayload) entry.Offset
            let readBack = Vx.readEntry buf entry
            Test.equalBytes "payload round-trip" payload readBack
        | Error e -> Test.isFalse (sprintf "expected Ok, got %A" e) true)

    Test.register "Vx.parse: bad magic -> BadMagic" (fun () ->
        let badMagic : byte[] =
            [| 0xFFuy; 0xFFuy; 0xFFuy; 0xFFuy; 0xFFuy; 0xFFuy; 0xFFuy; 0x02uy |]
        match Vx.parse badMagic with
        | Error Vx.BadMagic -> Test.isTrue "BadMagic" true
        | _ -> Test.isFalse "expected BadMagic" true)

    Test.register "Vx.parse: version 0x01 -> BadVersion" (fun () ->
        let v : byte[] =
            [| 0x52uy; 0x47uy; 0x53uy; 0x53uy; 0x41uy; 0x44uy; 0x00uy; 0x01uy |]
        match Vx.parse v with
        | Error (Vx.BadVersion b) -> Test.equal "version byte" (byte 0x01) b
        | _ -> Test.isFalse "expected BadVersion" true)

    Test.register "Vx.parse: high-bit name_len -> Truncated, no crash (I-1 regression)" (fun () ->
        // Before the fix, int(0xFFFFFFFA) = -6 slipped past the bounds check
        // (pos + (-6) > len is false), and `Array.zeroCreate<byte> -6` threw
        // ArgumentOutOfRangeException. Buffer is exactly 20 bytes: header(8) +
        // size(4, nonzero) + offset(4) + name_len(4); pos+12 = 20 <= 20, so the
        // entry header IS read and the negative-name_len guard actually fires.
        let header : byte[] =
            [| 0x52uy; 0x47uy; 0x53uy; 0x53uy; 0x41uy; 0x44uy; 0x00uy; 0x02uy |]
        let buf = Array.zeroCreate<byte> (header.Length + 12)
        Array.Copy(header, 0, buf, 0, header.Length)
        buf.[header.Length] <- 0x10uy        // size = 16 (nonzero → not the sentinel)
        // offset field (bytes 12..15) left zero
        buf.[header.Length + 8]  <- 0xFAuy   // name_len = 0xFFFFFFFA
        buf.[header.Length + 9]  <- 0xFFuy
        buf.[header.Length + 10] <- 0xFFuy
        buf.[header.Length + 11] <- 0xFFuy
        match Vx.parse buf with
        | Error Vx.Truncated -> Test.isTrue "got Truncated" true
        | Error e -> Test.isFalse (sprintf "expected Truncated, got %A" e) true
        | Ok _ -> Test.isFalse "expected Error not Ok" true)
