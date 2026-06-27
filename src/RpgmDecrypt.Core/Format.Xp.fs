namespace RpgmDecrypt.Core

/// RPG Maker XP `.rgssad` (version 1) archive walker.
///
/// File layout (reverse-engineered, documented in many community wikis;
/// cross-checked against Petschko's reading algorithm reference).
///
/// HEADER:
///   bytes 0..6  : 'RGSSAD\0' (7)
///   byte  7     : version = 0x01 (XP)
///
/// ENTRIES — for each packed file, in order:
///   u32 little-endian: name_len
///   bytes (name_len) : name, XOR-obfuscated with the magic key
///   u32 little-endian: size (the on-disk size of the payload, *not*
///                      zlib-decompressed)
///   u32 little-endian: offset (absolute position in the file)
///
/// Payload is zlib-deflated (raw deflate, no zlib header) — the engine
/// inflates on read. We identify each entry; the .rxdata content of MVP
/// MVP outputs is delivered as-is (we do not run the Ruby Marshal
/// interpreter; the user can pipe through Ruby if needed).
///
/// XOR key for filename obfuscation: `RGSSAD\0` cycling. The same 7-byte
/// payload is the XOR key — the archive's own header doubles as its own
/// deobfuscation key.
[<RequireQualifiedAccess>]
module Xp =

    open System

    type Entry =
        { Index: int
          Name: string
          Offset: int64
          Size: int32 }

    type ParseError =
        | ShortHeader
        | BadMagic
        | BadVersion of byte
        | Truncated

    // 7-byte magic prefix "RGSSAD\0" — explicit bytes so F# string
    // escape handling does not double the NUL terminator.
    let magicKey : byte[] =
        [| 0x52uy; 0x47uy; 0x53uy; 0x53uy; 0x41uy; 0x44uy; 0x00uy |]    // F#"RGSSAD\0" expands to 8 chars on .NET 10; keep bytes explicit

    let xorDecodeName (raw: byte[]) : string =
        if raw.Length = 0 then ""
        else
            let out = Array.zeroCreate<byte> raw.Length
            let keyLen = magicKey.Length
            for i in 0 .. raw.Length - 1 do
                out.[i] <- raw.[i] ^^^ magicKey.[i % keyLen]
            // strip trailing NUL if present
            let mutable endIdx = out.Length
            while endIdx > 0 && out.[endIdx - 1] = 0uy do
                endIdx <- endIdx - 1
            let slice = Array.zeroCreate<byte> endIdx
            Array.Copy(out, slice, endIdx)
            System.Text.Encoding.UTF8.GetString slice

    /// Read the integer at offset `pos` as little-endian u32.
    let private readU32LE (buf: byte[]) (pos: int) : uint32 =
        uint32 buf.[pos]
        ||| (uint32 buf.[pos + 1] <<< 8)
        ||| (uint32 buf.[pos + 2] <<< 16)
        ||| (uint32 buf.[pos + 3] <<< 24)

    /// Try to parse an XP `.rgssad` archive's table of contents.
    /// Returns `entries` plus the byte-offset of the first payload.
    let parse (buf: byte[]) : Result<Entry list * int, ParseError> =
        if buf.Length < 8 then Error ShortHeader
        elif not (Crypto.startsWith magicKey buf) then Error BadMagic
        elif buf.[7] <> 0x01uy then Error(BadVersion buf.[7])
        else
            let mutable pos = 8
            let mutable idx = 0
            let acc = ResizeArray<Entry>()
            let mutable keepGoing = true
            while keepGoing do
                if pos + 4 > buf.Length then keepGoing <- false
                else
                    let nameLen = readU32LE buf pos
                    pos <- pos + 4
                    if nameLen = 0u then keepGoing <- false
                    elif pos + int nameLen + 8 > buf.Length then
                        acc.Clear()
                        Error Truncated |> ignore
                        keepGoing <- false
                    else
                        let nameBytes = Array.zeroCreate<byte> (int nameLen)
                        Array.Copy(buf, pos, nameBytes, 0, int nameLen)
                        pos <- pos + int nameLen
                        let size = readU32LE buf pos
                        pos <- pos + 4
                        let offset = readU32LE buf pos
                        pos <- pos + 4
                        let nameStr = xorDecodeName nameBytes
                        let newEntry : Entry =
                            { Index = idx
                              Name = nameStr
                              Offset = int64 offset
                              Size = int32 size }
                        acc.Add newEntry
                        idx <- idx + 1
            if acc.Count = 0 then
                Error Truncated
            else
                Ok(List.ofSeq acc, pos)

    /// Convenience: parse a file from disk.
    let parseFile (path: string) :
        Result<Entry list * int, ParseError> =
        let bytes = System.IO.File.ReadAllBytes path
        parse bytes

    /// Extract raw payload bytes for one entry, including ZLIB wrapping.
    /// The caller decides whether to inflate or further process.
    let readEntry (buf: byte[]) (entry: Entry) : byte[] =
        let mutable start = int entry.Offset
        let mutable size  = int entry.Size
        if start < 0 || start >= buf.Length then [||] else
        if start + size > buf.Length then
            size <- buf.Length - start
        let slice = Array.zeroCreate<byte> size
        Array.Copy(buf, start, slice, 0, size)
        slice
