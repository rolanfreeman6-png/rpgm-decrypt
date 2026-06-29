module RpgmDecrypt.Tests.FormatXpTests

open System
open RpgmDecrypt.Core
open RpgmDecrypt.Tests.TestFramework

let register () : unit =
    Test.register "Xp.parse: synthetic version-1 archive yields 1 entry" (fun () ->
        let header : byte[] =
            [| 0x52uy; 0x47uy; 0x53uy; 0x53uy; 0x41uy; 0x44uy; 0x00uy; 0x01uy |]
        let fname = System.Text.Encoding.UTF8.GetBytes "Graphics/Hero.png"
        let payload : byte[] = [| 0xCAuy; 0xFEuy; 0xBAuy; 0xBEuy; 0xDEuy; 0xADuy; 0xBEuy; 0xEFuy |]
        let magicKey = Xp.magicKey
        let encodedName = Array.zeroCreate<byte> fname.Length
        for i = 0 to fname.Length - 1 do
            encodedName.[i] <- fname.[i] ^^^ magicKey.[i % magicKey.Length]
        // Real XP layout per Petschko:
        //   header | size(4) | offset(4) | name_len(4) | name
        //   | terminator-record (size=0+offset=0+name_len=0 = 12 zero bytes)
        //   | payload
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
        match Xp.parse buf with
        | Ok(entries, _) ->
            let entry = List.head entries
            let actualName = entry.Name
            let actualNameBytes =
                System.Text.Encoding.ASCII.GetBytes actualName
                |> Array.map (sprintf "%02x") |> String.concat " "
            let actualSize = entry.Size
            let actualOffset = entry.Offset
            let expPayload = payload.Length
            Test.equal "1 entry" 1 (List.length entries)
            Test.equal "name" "Graphics/Hero.png" actualName
            Test.equal "size" expPayload actualSize
            Test.equal "offset" (int64 posPayload) actualOffset
        | Error e -> Test.isFalse (sprintf "expected Ok, got %A" e) true)

    Test.register "Xp.parse: bad magic -> BadMagic" (fun () ->
        let badMagic : byte[] =
            [| 0xFFuy; 0xFFuy; 0xFFuy; 0xFFuy; 0xFFuy; 0xFFuy; 0xFFuy; 0x01uy |]
        match Xp.parse badMagic with
        | Error Xp.BadMagic -> Test.isTrue "BadMagic" true
        | _ -> Test.isFalse "expected BadMagic" true)

    Test.register "Xp.parse: version 0x02 -> BadVersion" (fun () ->
        let v : byte[] =
            [| 0x52uy; 0x47uy; 0x53uy; 0x53uy; 0x41uy; 0x44uy; 0x00uy; 0x02uy |]
        match Xp.parse v with
        | Error (Xp.BadVersion b) -> Test.equal "version byte" (byte 0x02) b
        | _ -> Test.isFalse "expected BadVersion" true)
