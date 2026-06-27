namespace RpgmDecrypt.Core

/// RPG Maker VX archive walker — extension `.rgssad` with version byte
/// 0x02, or `.rgss2a` extension. Same XOR-on-filename scheme as XP but
/// with slightly different byte layout (size + offset after name).
[<RequireQualifiedAccess>]
module Vx =

    open System

    // "RGSSAD\0" same as XP — 7 bytes, hard-coded.
    let magicKey : byte[] =
        [| 0x52uy; 0x47uy; 0x53uy; 0x53uy; 0x41uy; 0x44uy; 0x00uy |]    // F#"RGSSAD\0" expands to 8 chars on .NET 10; keep bytes explicit

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

    let xorDecodeName (raw: byte[]) : string =
        if raw.Length = 0 then ""
        else
            let out = Array.zeroCreate<byte> raw.Length
            let keyLen = magicKey.Length
            for i in 0 .. raw.Length - 1 do
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

    /// Layout: name_len, name, size, offset — same as XP. Just version byte differs.
    let parse (buf: byte[]) : Result<Entry list * int, ParseError> =
        if buf.Length < 8 then Error ShortHeader
        elif not (Crypto.startsWith magicKey buf) then Error BadMagic
        elif buf.[7] <> 0x02uy then Error(BadVersion buf.[7])
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
                        keepGoing <- false
                        Error Truncated |> ignore
                    else
                        let nameBytes = Array.zeroCreate<byte> (int nameLen)
                        Array.Copy(buf, pos, nameBytes, 0, int nameLen)
                        pos <- pos + int nameLen
                        let size = readU32LE buf pos
                        pos <- pos + 4
                        let offset = readU32LE buf pos
                        pos <- pos + 4
                        let newEntry : Entry =
                            { Index = idx
                              Name = xorDecodeName nameBytes
                              Offset = int64 offset
                              Size = int32 size }
                        acc.Add newEntry
                        idx <- idx + 1
            Ok(List.ofSeq acc, pos)

    let parseFile (path: string) : Result<Entry list * int, ParseError> =
        let bytes = System.IO.File.ReadAllBytes path
        parse bytes

    let readEntry (buf: byte[]) (entry: Entry) : byte[] =
        let mutable start = int entry.Offset
        let mutable size  = int entry.Size
        if start < 0 || start >= buf.Length then [||] else
        if start + size > buf.Length then size <- buf.Length - start
        let slice = Array.zeroCreate<byte> size
        Array.Copy(buf, start, slice, 0, size)
        slice
