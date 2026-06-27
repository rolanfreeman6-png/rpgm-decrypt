namespace RpgmDecrypt.Core

/// RPG Maker XP `.rgssad` (version 1) archive walker.
///
/// File layout per the publicly-documented RPG Maker archive format
/// (Petschko/RPG-Maker-MV-Decrypter — MIT, archive-only; cross-checked
/// against uuksu/RPGMakerDecrypter):
///
/// HEADER:
///   bytes 0..6  : 'RGSSAD\0'  (7 bytes — fixed-width ASCII magic)
///   byte  7     : version = 0x01 (XP)
///
/// ENTRIES — for each packed file, in order:
///   u32 little-endian: size       (on-disk size of the deflated payload)
///   u32 little-endian: offset     (absolute position in the file of the payload)
///   u32 little-endian: name_len   (length of name_bytes, including NUL terminator)
///   bytes (name_len) : name, XOR-obfuscated with the magic prefix bytes
///
/// Payload is zlib-deflated; we identify each entry's offset/size so the
/// user can pipe each entry through `zlib inflate` + `ruby Marshal.load`
/// in their toolchain of choice. We do not run the Ruby Marshal
/// interpreter ourselves (security posture — see docs/THEORY.md §8).
///
/// XOR key for filename obfuscation: the 7-byte RGSSAD magic itself,
/// cycling. The archive's own header doubles as its own deobfuscation key.
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
            for i = 0 to raw.Length - 1 do
                out.[i] <- raw.[i] ^^^ magicKey.[i % keyLen]
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
    /// Per reverse-engineered public algorithm: entries terminate when
    /// `name_len = 0` (a u32 = 0 sentinel at the end of the table).
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
                if pos + 12 > buf.Length then keepGoing <- false
                else
                    let size   = readU32LE buf pos
                    pos <- pos + 4
                    let offset = readU32LE buf pos
                    pos <- pos + 4
                    let nameLen = readU32LE buf pos
                    pos <- pos + 4
                    let nameLenInt = int nameLen
                    if nameLen = 0u then
                        // Sentinel: end of entries table.
                        keepGoing <- false
                    elif nameLenInt < 0
                         || pos + nameLenInt > buf.Length then
                        // nameLen is either wrapped negative or has no room
                        // in the buffer; treat as truncated header rather
                        // than throw inside `Array.Copy`.
                        acc.Clear()
                        Error Truncated |> ignore
                        keepGoing <- false
                    else
                        let nameBytes = Array.zeroCreate<byte> nameLenInt
                        Array.Copy(buf, pos, nameBytes, 0, nameLenInt)
                        pos <- pos + nameLenInt
                        let newEntry : Entry =
                            { Index = idx
                              Name = xorDecodeName nameBytes
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
