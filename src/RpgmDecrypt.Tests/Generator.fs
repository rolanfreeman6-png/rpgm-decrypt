/// Fixtures / Generator
/// Builds synthetic-but-realistic RPG Maker game directory trees for
/// black-box testing of `Report.run` and the CLI binary. The bytes we
/// emit here are byte-exact and known, so we can assert round-trip
/// equality on every decrypt. Nothing in this module is committed to
/// the repo's test corpus; usage is hermetic.
namespace RpgmDecrypt.Tests

open System
open RpgmDecrypt.Core

open System.IO
open System.IO.Compression

module Generator =

    /// Fixed key for every synthetic fixture. Decoded form is
    /// `0xDE 0xAD 0xBE 0xEF 0xCA 0xFE 0xBA 0xBE 0x00 0x01 0x02 0x03 0x04
    ///  0x05 0x06 0x07` — memorable, deterministic.
    let syntheticKey : byte[] =
        System.Convert.FromHexString "DEADBEEFCAFEBABE0001020304050607"

    /// A deterministic PNG-like header we recognize as plaintext. Not a real
    /// PNG (no IDAT chunk) but every byte is reproducible. Public so test
    /// bodies can verify decrypted bytes against the canonical plaintext.
    let fakePngHeader : byte[] =
        System.Convert.FromHexString
            ("89504E470D0A1A0A0000000D49484452" +
             "000000400000004008060000004B6D3F87" +
             "0000000049454E44AE426082")

    let pad16 (b: byte[]) : byte[] =
        let out = Array.zeroCreate<byte> (b.Length + (16 - b.Length % 16))
        Array.Copy(b, out, b.Length)
        out

    /// Build a realistic MV game with multiple encrypted assets across
    /// multiple folders. Returns the gameDir root.
    let buildSyntheticMvGame (root: string) : unit =
        if Directory.Exists root then Directory.Delete(root, true)
        Directory.CreateDirectory root |> ignore
        Directory.CreateDirectory(Path.Combine(root, "www", "img", "Characters")) |> ignore
        Directory.CreateDirectory(Path.Combine(root, "www", "img", "Tilesets")) |> ignore
        Directory.CreateDirectory(Path.Combine(root, "www", "img", "Faces")) |> ignore
        Directory.CreateDirectory(Path.Combine(root, "www", "img", "Enemies")) |> ignore
        Directory.CreateDirectory(Path.Combine(root, "www", "img", "System")) |> ignore
        Directory.CreateDirectory(Path.Combine(root, "www", "audio", "BGM")) |> ignore
        Directory.CreateDirectory(Path.Combine(root, "www", "audio", "BGS")) |> ignore
        Directory.CreateDirectory(Path.Combine(root, "www", "audio", "ME")) |> ignore
        Directory.CreateDirectory(Path.Combine(root, "www", "audio", "SE")) |> ignore
        Directory.CreateDirectory(Path.Combine(root, "www", "js")) |> ignore
        Directory.CreateDirectory(Path.Combine(root, "www", "movies")) |> ignore
        File.WriteAllText(Path.Combine(root, "package.json"),
                          """{"name":"RVJS_PROJECT","title":"Synthetic MV Game","rpgmaker":{"engine":"mv"}}""")
        // System.json with real-looking key
        File.WriteAllText(
            Path.Combine(root, "www", "js", "System.json"),
            sprintf
                """{"encryptionKey":"%s","gameTitle":"Synthetic Test","gameVersion":[{"major":1,"minor":0,"patch":0}],"switches":[""],"variables":[""],"versionId":1}"""
                (System.Convert.ToHexString syntheticKey))
        let entries : (string * byte[]) list =
            [ "www/img/Characters/$Hero.png",  pad16 fakePngHeader
              "www/img/Tilesets/Outside.png",    pad16 fakePngHeader
              "www/img/Tilesets/Inside_A1.png", pad16 fakePngHeader
              "www/img/Faces/Face1.png",         pad16 fakePngHeader
              "www/img/Enemies/Slime.png",       pad16 fakePngHeader ]
        for (rel, plain) in entries do
            let cipher = Crypto.xorTransform syntheticKey plain
            File.WriteAllBytes(Path.Combine(root, rel + "_"), cipher)
        // One unencrypted PNG file (pass-through path).
        File.WriteAllBytes(Path.Combine(root, "www", "img", "System", "Balloon.png"), fakePngHeader)
        // Synthetic ogg/m4a bytes — any plaintext magic OggS at offset 0 after XOR is recognised.
        let fakeOgg =
            System.Text.Encoding.ASCII.GetBytes
                "OggS\x00\x02\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00"
        let fakeOggCipher = Crypto.xorTransform syntheticKey fakeOgg
        for rel in
            [ "www/audio/BGM/Theme1.ogg_"
              "www/audio/BGS/Wind.ogg_"
              "www/audio/ME/Victory.ogg_"
              "www/audio/SE/Cursor.m4a_" ] do
            File.WriteAllBytes(Path.Combine(root, rel), fakeOggCipher)
        File.WriteAllBytes(Path.Combine(root, "www", "movies", "Intro.rpgmvp"), fakeOggCipher)

    /// Build a synthetic MZ .pak file containing one MV-encrypted PNG entry.
    let buildSyntheticMzPak (pakPath: string) (cipherPng: byte[]) : unit =
        if File.Exists pakPath then File.Delete pakPath
        use ms = new MemoryStream()
        use archive = new ZipArchive(ms, ZipArchiveMode.Create, leaveOpen = true)
        let e = archive.CreateEntry "www/img/test.png"
        use es = e.Open()
        es.Write(cipherPng, 0, cipherPng.Length)
        archive.Dispose()
        File.WriteAllBytes(pakPath, ms.ToArray())

    /// Build a synthetic XP .rgssad (v1) archive with one entry.
    /// Layout per Petschko's reading algorithm:
    ///   header | entry record | terminator-record | payload bytes
    ///   Header:           8 bytes "RGSSAD\0\x01"
    ///   Entry record:     size(4) | offset(4) | name_len(4) | name(N)
    ///   Terminator record: size=0 | offset=0 | name_len=0  (12 zero bytes)
    ///                      The parser recognises name_len=0 as end-of-table.
    ///   Payload:          bytes declared by entry.offset (here, placed
    ///                      immediately after the terminator for layout simplicity).
    let buildSyntheticXpRgssad (path: string) (filename: string) (payload: byte[]) : unit =
        if File.Exists path then File.Delete path
        let header : byte[] =
            [| 0x52uy; 0x47uy; 0x53uy; 0x53uy; 0x41uy; 0x44uy; 0x00uy; 0x01uy |]
        let fname = System.Text.Encoding.UTF8.GetBytes(filename)
        let magicKey = Xp.magicKey
        let encodedName = Array.zeroCreate<byte> fname.Length
        for i = 0 to fname.Length - 1 do
            encodedName.[i] <- fname.[i] ^^^ magicKey.[i % magicKey.Length]
        let posEntry         = header.Length
        let posNameStart     = posEntry + 12
        let posTerminator    = posNameStart + fname.Length
        let posPayload       = posTerminator + 12
        let total            = posPayload + payload.Length
        let buf = Array.zeroCreate<byte> total
        Array.Copy(header, 0, buf, 0, header.Length)
        // size (LE u32)
        buf.[posEntry]     <- byte payload.Length
        buf.[posEntry + 1] <- 0uy
        buf.[posEntry + 2] <- 0uy
        buf.[posEntry + 3] <- 0uy
        // offset (LE u32) pointing at payload
        buf.[posEntry + 4] <- byte posPayload
        buf.[posEntry + 5] <- 0uy
        buf.[posEntry + 6] <- 0uy
        buf.[posEntry + 7] <- 0uy
        // name_len (LE u32)
        buf.[posEntry + 8]  <- byte fname.Length
        buf.[posEntry + 9]  <- 0uy
        buf.[posEntry + 10] <- 0uy
        buf.[posEntry + 11] <- 0uy
        Array.Copy(encodedName, 0, buf, posNameStart, fname.Length)
        // Terminator record: 12 zero bytes (already 0 by Array.zeroCreate).
        // Payload bytes.
        Array.Copy(payload, 0, buf, posPayload, payload.Length)
        File.WriteAllBytes(path, buf)
