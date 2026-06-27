namespace RpgmDecrypt.Core

/// RPG Maker VX Ace archive walker — extension `.rgss3a`, version byte 0x03.
///
/// Layout per publicly-documented algorithm (uuksu/RPGMakerDecrypter RGSSADv3.cs,
/// MIT-licensed, used as algorithm reference only — no code copied):
///
/// HEADER:
///   bytes 0..6  : 'RGSSAD\0' (7 bytes)
///   byte  7     : version = 0x03 (VX Ace)
///   bytes 8..11 : master-seed (u32 LE)
///   master-key  : master-seed * 9 + 3
///
/// ENTRY — per file in archive, in order:
///   u32 little-endian : offset   (decrypted via master-key XOR)
///   u32 little-endian : size     (decrypted via master-key XOR)
///   u32 little-endian : entry-key (decrypted via master-key XOR; THIS is
///                                     the per-file rotation key for payload)
///   u32 little-endian : name-length (decrypted via master-key XOR)
///   bytes (n)        : name (decrypted byte-by-byte via VxAceKey module)
///                     (terminator: when decrypted offset == 0, loop ends
///                      and no payload bytes follow.)
///
/// This header now uses the *real* layout; the previous variant mixed up
/// the order of fields. The fixture test asserts all four fields decrypt
/// correctly against canonical vectors.
[<RequireQualifiedAccess>]
module VxAce =

    open System
    open System.IO

    type Entry =
        { Index: int
          Name: string
          Offset: int64
          Size: int32
          Key: uint32 }

    type ParseError =
        | ShortHeader
        | BadMagic
        | BadVersion of byte
        | Truncated

    // 7-byte magic prefix "RGSSAD\0" — explicit bytes so F#\0 escape
    // (which expands to two characters on .NET 10) does not enter.
    let magicKey : byte[] =
        [| 0x52uy; 0x47uy; 0x53uy; 0x53uy; 0x41uy; 0x44uy; 0x00uy |]

    let xorDecodeName (raw: byte[]) : string =
        // Kept for backwards-compat with synthetic fixtures — RGSS1/X
        // uses pure XOR-with-magic-prefix for filenames. Real VxAce
        // uses VxAceKey.decodeFilename (master-key-based), invoked in parse.
        if raw.Length = 0 then ""
        else
            let out = Array.zeroCreate<byte> raw.Length
            let keyLen = magicKey.Length
            for i = 0 to raw.Length - 1 do
                out.[i] <- raw.[i] ^^^ magicKey.[i % keyLen]
            let mutable endIdx = out.Length
            while endIdx > 0 && out.[endIdx - 1] = 0uy do
                endIdx <- endIdx - 1
            let slice = Array.zeroCreate<byte> endIdx
            Array.Copy(out, slice, endIdx)
            System.Text.Encoding.UTF8.GetString slice

    let private readU32LE (buf: byte[]) (pos: int) : uint32 =
        uint32 buf.[pos]
        ||| (uint32 buf.[pos + 1] <<< 8)
        ||| (uint32 buf.[pos + 2] <<< 16)
        ||| (uint32 buf.[pos + 3] <<< 24)

    /// Try to parse an RGSS3 (VX Ace) `.rgss3a` archive.
    let parse (buf: byte[]) : Result<Entry list, ParseError> =
        if buf.Length < 12 then Error ShortHeader
        elif not (Crypto.startsWith magicKey buf) then Error BadMagic
        elif buf.[7] <> 0x03uy then Error(BadVersion buf.[7])
        else
            let masterKey = VxAceKey.deriveMasterKey buf 8
            let mutable pos = 12  // skip 8-byte header + 4-byte master-seed
            let mutable idx = 0
            let acc = ResizeArray<Entry>()
            let mutable keepGoing = true
            while keepGoing do
                if pos + 16 > buf.Length then keepGoing <- false
                else
                    let rawOff    = readU32LE buf pos
                    pos <- pos + 4
                    let rawSize   = readU32LE buf pos
                    pos <- pos + 4
                    let rawEKey   = readU32LE buf pos
                    pos <- pos + 4
                    let rawNameLen= readU32LE buf pos
                    pos <- pos + 4
                    let off     = VxAceKey.decodeUInt32 rawOff    masterKey
                    let sizeV   = VxAceKey.decodeUInt32 rawSize   masterKey
                    let eKey    = VxAceKey.decodeUInt32 rawEKey   masterKey
                    let nLenV   = VxAceKey.decodeUInt32 rawNameLen masterKey
                    let sizeInt = int32 (int sizeV)
                    let nLenInt = int nLenV
                    // uuksu's loop-end sentinel: decrypted offset == 0.
                    if off = 0u then
                        keepGoing <- false
                    // Defensive guard: nameLen may wrap on real archives.
                    elif nLenInt < 0 || pos + nLenInt > buf.Length then
                        acc.Clear()
                        Error Truncated |> ignore
                        keepGoing <- false
                    else
                        let nameBytes = Array.zeroCreate<byte> nLenInt
                        Array.Copy(buf, pos, nameBytes, 0, nLenInt)
                        pos <- pos + nLenInt
                        let name = VxAceKey.decodeFilename nameBytes masterKey
                        let newEntry : Entry =
                            { Index = idx
                              Name = name
                              Offset = int64 (int off)
                              Size  = sizeInt
                              Key   = eKey }
                        acc.Add newEntry
                        idx <- idx + 1
            if acc.Count = 0 then
                Error Truncated
            else
                Ok(List.ofSeq acc)

    let parseFile (path: string) : Result<Entry list, ParseError> =
        let bytes = File.ReadAllBytes path
        parse bytes

    /// Extract the raw payload for one entry from the archive buffer.
    let readEntry (buf: byte[]) (entry: Entry) : byte[] =
        let mutable start = int entry.Offset
        let mutable size  = int entry.Size
        if start < 0 || start >= buf.Length then [||]
        else
            if start + size > buf.Length then
                size <- buf.Length - start
            let slice = Array.zeroCreate<byte> size
            Array.Copy(buf, start, slice, 0, size)
            slice

    /// Decrypt a payload buffer (post-XOR) using uuksu's per-file rotation.
    /// Pure function — does not perform any file I/O.
    let decryptPayload (entry: Entry) (cipher: byte[]) : byte[] =
        VxAceKey.decodePayload cipher entry.Key
