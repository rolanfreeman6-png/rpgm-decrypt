module RpgmDecrypt.Tests.FormatVxAceTests

open System
open RpgmDecrypt.Core
open RpgmDecrypt.Tests.TestFramework

let register () : unit =
    Test.register "VxAce.parse: end-to-end encrypt+parse yields 1 entry, decrypted payload word-exact" (fun () ->
        // We embed here a small but real-shape VX Ace archive, then test:
        //   * parse extracts the entry with all 4 fields correctly decrypted
        //   * decryptPayload reproduces the original plaintext word-exact
        let header : byte[] =
            [| 0x52uy; 0x47uy; 0x53uy; 0x53uy; 0x41uy; 0x44uy; 0x00uy; 0x03uy |]
        // Master seed = 0x00000005 LE  →  masterKey = 5 * 9 + 3 = 0x00000030 (=48)
        let masterSeed = 5u
        let masterKey = masterSeed * 9u + 3u
        // Pick a real-looking RGSS3 filename. We'll XOR-encode it with
        // the master key 4-byte cycling.
        let fnamePlain = "Graphics/Hero.rvdata2"
        let fnameBytes = System.Text.Encoding.UTF8.GetBytes fnamePlain
        let fnameBytesLen = fnameBytes.Length
        let safe (b: byte) = if int b < 0 then byte (256 + int b) else b
        let mkBytes () =
            [| safe (byte masterKey)
               safe (byte (masterKey >>>  8))
               safe (byte (masterKey >>> 16))
               safe (byte (masterKey >>> 24)) |]
        let encodedName = Array.zeroCreate<byte> fnameBytesLen
        for i in 0 .. fnameBytesLen - 1 do
            let kb = mkBytes ()
            encodedName.[i] <- fnameBytes.[i] ^^^ kb.[i % 4]
        // Pick a per-entry key + payload plaintext (15 bytes "RPGVXAce\nMagic\n".
        let entryKey = 0u
        let plainPayload = System.Text.Encoding.ASCII.GetBytes "RPGVXAce Magic!"
        // Encrypt the payload with the rotating-entry key (until rotated away).
        // Note XOR is symmetric so the same routine works for both.
        let cipherPayload =
            let out = Array.zeroCreate<byte> plainPayload.Length
            let mutable tempKey = entryKey
            let mutable kb =
                [| safe (byte tempKey)
                   safe (byte (tempKey >>>  8))
                   safe (byte (tempKey >>> 16))
                   safe (byte (tempKey >>> 24)) |]
            let mutable j = 0
            for i in 0 .. plainPayload.Length - 1 do
                out.[i] <- plainPayload.[i] ^^^ kb.[j]
                j <- j + 1
                if j = 4 then
                    tempKey <- tempKey * 7u + 3u
                    kb <-
                        [| safe (byte tempKey)
                           safe (byte (tempKey >>>  8))
                           safe (byte (tempKey >>> 16))
                           safe (byte (tempKey >>> 24)) |]
                    j <- 0
            out
        // Now we lay out the RGSSAD on-disk structure and XOR-encrypt
        // the integer fields with the master key. Layout:
        //   pos 0..7   = header (RGSSAD\0\x03)
        //   pos 8..11  = master seed = 5          (LE)
        //   per entry (16-byte header + N name bytes):
        //     u32 LE : decoded-offset (= posPayload)
        //     u32 LE : decoded-size   (= cipherPayload.Length)
        //     u32 LE : per-entry-key  (= entryKey = 0)
        //     u32 LE : decoded-nameLen (= fnamePlain.Length)
        //     bytes N : encoded-name (16 bytes XOR'd with masterKey)
        //   end terminator: u32 all-zero (decoded offset==0)
        let posPayload = header.Length + 4 + 16 + fnameBytesLen + 4
        let total = posPayload + cipherPayload.Length
        let buf = Array.zeroCreate<byte> total
        Array.Copy(header, 0, buf, 0, header.Length)
        let posSeed = header.Length
        buf.[posSeed]     <- byte masterSeed
        buf.[posSeed + 1] <- 0uy
        buf.[posSeed + 2] <- 0uy
        buf.[posSeed + 3] <- 0uy
        let posOffEntry = posSeed + 4

        let writeEncryptedU32 (pos: int) (plain: uint32) =
            let plainBytes =
                [| safe (byte plain)
                   safe (byte (plain >>>  8))
                   safe (byte (plain >>> 16))
                   safe (byte (plain >>> 24)) |]
            let mb = mkBytes ()
            buf.[pos]     <- plainBytes.[0] ^^^ mb.[0]
            buf.[pos + 1] <- plainBytes.[1] ^^^ mb.[1]
            buf.[pos + 2] <- plainBytes.[2] ^^^ mb.[2]
            buf.[pos + 3] <- plainBytes.[3] ^^^ mb.[3]

        let posOffField = posOffEntry
        writeEncryptedU32 posOffField        (uint32 posPayload)
        writeEncryptedU32 (posOffField + 4)  (uint32 cipherPayload.Length)
        writeEncryptedU32 (posOffField + 8)  entryKey
        writeEncryptedU32 (posOffField + 12) (uint32 fnameBytesLen)
        Array.Copy(encodedName, 0, buf, posOffEntry + 16, fnameBytesLen)
        Array.Copy(cipherPayload, 0, buf, posPayload, cipherPayload.Length)
        // Terminator: write a synthetic entry whose decoded offset is 0.
        // Per uuksu: the loop ends when a 12-byte header reads to offset==0.
        // Since bytes XOR'd with masterKey=0x30, we write the value 0x30 0x00 0x00 0x00
        // for the four terminator u32 fields (deconding yields 0 0 0 0, matching sentinel).
        let posTermOff = posOffField + 16 + fnameBytesLen  // after entry: right before payload
        writeEncryptedU32 posTermOff       0u   // offset  →  decodes to 0  → stops loop
        // The other 3 terminator fields are unused (loop exits after reading offset);
        // leave them zero in pain-array.

        match VxAce.parse buf with
        | Ok entries ->
            Test.equal "1 entry parsed" 1 (List.length entries)
            let e = List.head entries
            Test.equal "name matches" fnamePlain e.Name
            Test.equal "size matches" cipherPayload.Length e.Size
            // Verify decryption word-exact.
            let sliced = Array.zeroCreate<byte> cipherPayload.Length
            Array.Copy(buf, int e.Offset, sliced, 0, cipherPayload.Length)
            let plain = VxAce.decryptPayload e sliced
            Test.equalBytes "decrypted payload byte-exact" plainPayload plain
        | Error e ->
            // Print buf to diagnose: hex of first 64 bytes.
            let dump =
                buf.[0..63]
                |> Seq.mapi (fun i b -> i.ToString("X2") + "=" + b.ToString("X2"))
                |> Seq.truncate 32
                |> String.concat ", "
            eprintfn "parse failed: %A\nbuf[0..63]: %s" e dump
            Test.isFalse (sprintf "expected Ok, got %A" e) true)

    Test.register "VxAceKey.decodeFootnote: master-key derivation cycle key" (fun () ->
        // Test the master-key formula: masterKey = seed * 9 + 3.
        let seed0 : byte[] = [| 0uy; 0uy; 0uy; 0uy |]
        let r0 =
            let local = VxAceKey.deriveMasterKey seed0 0
            if local = 3u then Test.isTrue "seed 0 -> 3" true
            else Test.isFalse (sprintf "expected 3, got %d" local) true
        r0 |> ignore
        let seed1 : byte[] = [| 0x04uy; 0x03uy; 0x02uy; 0x01uy |] // 0x01020304 LE
        let r1 = VxAceKey.deriveMasterKey seed1 0
        if r1 = (0x01020304u * 9u + 3u) then Test.isTrue "seed 0x01020304 -> 0x09061C27" true
        else Test.isFalse (sprintf "expected 0x%X, got 0x%X" (0x01020304u * 9u + 3u) r1) true
        r1 |> ignore)

    Test.register "VxAce.parse: negative-truncated-name_len -> Truncated, no crash" (fun () ->
        // Regression test: on 2026-06-27 against F:\fr\g\HC_EP1\Game.rgss3a
        // (real RPG Maker VX Ace shipped game, 39 MB, 1914 entries) the parser
        // threw ArgumentException("count=-1110938460") because reading a real
        // uint32 name_len field cast to int32 yielded a negative value;
        // we now guard explicitly.
        let header : byte[] =
            [| 0x52uy; 0x47uy; 0x53uy; 0x53uy; 0x41uy; 0x44uy; 0x00uy; 0x03uy |]
        let buf = Array.zeroCreate<byte> (header.Length + 16)
        Array.Copy(header, 0, buf, 0, header.Length)
        // Skip master seed slot (4 bytes); start of first entry record.
        // First entry: name_len(4)+= 0xFFFFFFFA which overflows to -6 in int.
        buf.[header.Length + 4] <- 0xFAuy
        buf.[header.Length + 5] <- 0xFFuy
        buf.[header.Length + 6] <- 0xFFuy
        buf.[header.Length + 7] <- 0xFFuy
        // No actual name bytes (16 bytes total length; loop expects 16 + name_len)
        match VxAce.parse buf with
        | Error VxAce.Truncated -> Test.isTrue "got Truncated" true
        | Error e -> Test.isFalse (sprintf "expected Truncated, got %A" e) true
        | Ok _ -> Test.isFalse "expected Error not Ok" true)

    Test.register "VxAce.parse: bad magic -> BadMagic" (fun () ->
        // Magic must fail: first 7 bytes != RGSSAD\0. Make 16-byte buffer.
        let bad : byte[] =
            [| 0x42uy; 0x47uy; 0x53uy; 0x53uy; 0x41uy; 0x44uy; 0x00uy; 0x03uy
               0x00uy; 0x00uy; 0x00uy; 0x00uy
               0x00uy; 0x00uy; 0x00uy; 0x00uy |]
        match VxAce.parse bad with
        | Error VxAce.BadMagic -> Test.isTrue "BadMagic" true
        | _ -> Test.isFalse "expected BadMagic" true)

    Test.register "VxAce.parse: version != 0x03 -> BadVersion" (fun () ->
        let v : byte[] =
            [| 0x52uy; 0x47uy; 0x53uy; 0x53uy; 0x41uy; 0x44uy; 0x00uy; 0x01uy
               0x00uy; 0x00uy; 0x00uy; 0x00uy |]
        match VxAce.parse v with
        | Error (VxAce.BadVersion b) -> Test.equal "version byte" (byte 0x01) b
        | _ -> Test.isFalse "expected BadVersion" true)
