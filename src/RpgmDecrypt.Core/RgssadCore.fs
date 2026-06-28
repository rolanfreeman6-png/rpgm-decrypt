namespace RpgmDecrypt.Core

/// Shared table-of-contents parser for RPG Maker XP (`0x01`) and VX (`0x02`)
/// `.rgssad` archives.
///
/// Both engines use the identical on-disk entry layout
///   `size(4) | offset(4) | name_len(4) | name(name_len)`
/// with filenames XOR-obfuscated by the 7-byte RGSSAD magic. They differ only
/// in the version byte and the end-of-table sentinel. Keeping the loop here —
/// rather than duplicated in Format.Xp.fs and Format.Vx.fs — means the bounds
/// and negative-`name_len` guard can never drift between the two formats again
/// (the original drift was AUDIT finding I-1).
///
/// VX Ace (`0x03`) is deliberately NOT handled here: it derives a master key
/// from a seed, encrypts every header field, and has per-entry payload
/// encryption — a genuinely different algorithm that lives in Format.VxAce.fs.
[<RequireQualifiedAccess>]
module RgssadCore =

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

    /// End-of-table rule — the only behavioural difference between XP and VX.
    type Sentinel =
        | NameLenZero      // XP: a name_len of 0 terminates the table
        | SizeAndNameZero  // VX: size = 0 && name_len = 0 terminates the table

    // 7-byte "RGSSAD\0" — explicit bytes; F# "RGSSAD\0" expands to 8 chars on
    // .NET 10, so we keep the array literal.
    let magicKey : byte[] =
        [| 0x52uy; 0x47uy; 0x53uy; 0x53uy; 0x41uy; 0x44uy; 0x00uy |]

    /// Filenames are XOR-obfuscated with the cycling magic prefix; trailing
    /// NULs (padding) are trimmed before decoding as UTF-8.
    let xorDecodeName (raw: byte[]) : string =
        if raw.Length = 0 then ""
        else
            let out = Array.zeroCreate<byte> raw.Length
            let keyLen = magicKey.Length
            for i = 0 to raw.Length - 1 do
                out.[i] <- raw.[i] ^^^ magicKey.[i % keyLen]
            let mutable endIdx = out.Length
            while endIdx > 0 && out.[endIdx - 1] = 0uy do endIdx <- endIdx - 1
            let slice = Array.zeroCreate<byte> endIdx
            Array.Copy(out, slice, endIdx)
            System.Text.Encoding.UTF8.GetString slice

    let private readU32LE (buf: byte[]) (pos: int) : uint32 =
        uint32 buf.[pos]
        ||| (uint32 buf.[pos + 1] <<< 8)
        ||| (uint32 buf.[pos + 2] <<< 16)
        ||| (uint32 buf.[pos + 3] <<< 24)

    /// Parse the entry table. Returns the entries plus the byte-offset one past
    /// the last record read. `version` is the expected byte at offset 7;
    /// `sentinel` is the format's end-of-table rule.
    let parse (version: byte) (sentinel: Sentinel) (buf: byte[])
        : Result<Entry list * int, ParseError> =
        if buf.Length < 8 then Error ShortHeader
        elif not (Crypto.startsWith magicKey buf) then Error BadMagic
        elif buf.[7] <> version then Error(BadVersion buf.[7])
        else
            let mutable pos = 8
            let mutable idx = 0
            let acc = ResizeArray<Entry>()
            let mutable keepGoing = true
            while keepGoing do
                if pos + 12 > buf.Length then keepGoing <- false
                else
                    let size    = readU32LE buf pos
                    pos <- pos + 4
                    let offset  = readU32LE buf pos
                    pos <- pos + 4
                    let nameLen = readU32LE buf pos
                    pos <- pos + 4
                    let nameLenInt = int nameLen
                    let isEnd =
                        match sentinel with
                        | NameLenZero     -> nameLen = 0u
                        | SizeAndNameZero -> nameLen = 0u && size = 0u
                    if isEnd then
                        keepGoing <- false
                    elif nameLenInt < 0 || pos + nameLenInt > buf.Length then
                        // nameLen wrapped negative (high bit set) or runs past
                        // the buffer; treat as a corrupt/truncated table rather
                        // than throwing inside Array.zeroCreate/Array.Copy.
                        // Clearing acc makes the post-loop count check report
                        // Truncated.
                        acc.Clear()
                        keepGoing <- false
                    else
                        let nameBytes = Array.zeroCreate<byte> nameLenInt
                        Array.Copy(buf, pos, nameBytes, 0, nameLenInt)
                        pos <- pos + nameLenInt
                        acc.Add
                            { Index = idx
                              Name = xorDecodeName nameBytes
                              Offset = int64 offset
                              Size = int32 size }
                        idx <- idx + 1
            if acc.Count = 0 then Error Truncated
            else Ok(List.ofSeq acc, pos)

    /// Extract the raw payload bytes for one entry (ZLIB wrapping intact).
    let readEntry (buf: byte[]) (entry: Entry) : byte[] =
        let start = int entry.Offset
        let mutable size = int entry.Size
        if start < 0 || start >= buf.Length then [||]
        else
            if start + size > buf.Length then size <- buf.Length - start
            let slice = Array.zeroCreate<byte> size
            Array.Copy(buf, start, slice, 0, size)
            slice
