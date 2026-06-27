module RpgmDecrypt.Tests.FormatXpTests

open System
open RpgmDecrypt.Core
open RpgmDecrypt.Tests.TestFramework

let register () : unit =
    Test.register "Xp.parse: synthetic version-1 archive yields 1 entry" (fun () ->
        let header : byte[] =
            [| 0x52uy; 0x47uy; 0x53uy; 0x53uy; 0x41uy; 0x44uy; 0x00uy; 0x01uy |]
        let fname = System.Text.Encoding.UTF8.GetBytes "Graphics/Hero.png"
        let magicKey = Xp.magicKey
        let encodedName = Array.zeroCreate<byte> fname.Length
        for i = 0 to fname.Length - 1 do
            encodedName.[i] <- fname.[i] ^^^ magicKey.[i % magicKey.Length]
        // Real XP layout: size(4) + offset(4) + name_len(4) + name
        // (Petschko/RPG-Maker-MV-Decrypter, MIT).
        let total = header.Length + 4 + 4 + 4 + fname.Length
        let buf = Array.zeroCreate<byte> total
        Array.Copy(header, 0, buf, 0, header.Length)
        let mutable pos = header.Length
        // size (LE u32)
        buf.[pos]     <- 100uy
        buf.[pos + 1] <- 0uy
        buf.[pos + 2] <- 0uy
        buf.[pos + 3] <- 0uy
        pos <- pos + 4
        // offset (LE u32)
        buf.[pos]     <- 30uy
        buf.[pos + 1] <- 0uy
        buf.[pos + 2] <- 0uy
        buf.[pos + 3] <- 0uy
        pos <- pos + 4
        // name_len (LE u32)
        buf.[pos]     <- byte fname.Length
        buf.[pos + 1] <- 0uy
        buf.[pos + 2] <- 0uy
        buf.[pos + 3] <- 0uy
        pos <- pos + 4
        Array.Copy(encodedName, 0, buf, pos, fname.Length)
        match Xp.parse buf with
        | Ok(entries, _) ->
            Test.equal "1 entry" 1 (List.length entries)
            Test.equal "name" "Graphics/Hero.png" entries.Head.Name
            Test.equal "size" 100 entries.Head.Size
            Test.equal "offset" 30L entries.Head.Offset
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
