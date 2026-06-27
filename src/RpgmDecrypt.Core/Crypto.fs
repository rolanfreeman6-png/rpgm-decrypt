namespace RpgmDecrypt.Core

open System

/// Crypto primitives for the RPG Maker XOR scheme.
///
/// The MV and MZ engines share a single symmetric operation:
///
///     cipher_byte[i] = plain_byte[i] XOR key[i MOD keyLength]
///
/// The same byte stream XOR-applied against the same key produces the
/// plaintext; applying the XOR twice on a ciphertext gives back the
/// ciphertext (XOR is involutory). So we have one function, no separate
/// "decrypt key" — and the same call we test below proves it.
///
/// Specs / references (clean room):
///   * rpgmakerweb.com public docs: <https://rpgmakerweb.com>
///   * reverse-engineered algorithm publicly documented in many community
///     wikis; cross-checked against uuksu/RPGMakerDecrypter (MIT, public
///     source — used as a reference for byte ordering, never copy-pasted)
///     and Petschko/RPG-Maker-MV-Decrypter (MIT, archive-only).
module Crypto =

    let private ascii (s: string) : byte[] =
        System.Text.Encoding.ASCII.GetBytes s

    // ---- Magic-byte constants ---------------------------------------------
    let magicMvHeader     : byte[] = ascii "RPGMV"
    let magicMzHeader     : byte[] = ascii "RPGMZ"
    let magicRgssadPrefix : byte[] = ascii "RGSSAD\0" // 7 bytes
    // PNG header carries 0x89, outside ASCII's 7-bit range; we hard-code
    // the eight bytes so the result is byte-exact (Encoding.ASCII would
    // silently map 0x89 -> '?'). RFC 2083 PNG signature.
    let magicPng  : byte[] =
        [| 0x89uy; 0x50uy; 0x4Euy; 0x47uy; 0x0Duy; 0x0Auy; 0x1Auy; 0x0Auy |]
    let magicOgg  : byte[] = ascii "OggS"
    let magicM4a  : byte[] = ascii "ftyp"
    let magicRiff : byte[] = ascii "RIFF"
    let magicWebp : byte[] = ascii "WEBP"
    let magicJpg  : byte[] = [| 0xFFuy; 0xD8uy; 0xFFuy |]

    /// Proper equality helper for fixed-size substrings inside a larger array.
    let subArrayEq (offset: int) (length: int) (expected: byte[]) (arr: byte[]) : bool =
        if arr.Length < offset + length then false
        elif expected.Length < length then false
        else
            let mutable ok = true
            for i in 0 .. length - 1 do
                if arr.[offset + i] <> expected.[i] then ok <- false
            ok

    /// Does `arr` start with the bytes of `prefix`?
    let startsWith (prefix: byte[]) (arr: byte[]) : bool =
        if arr.Length < prefix.Length then false
        else subArrayEq 0 prefix.Length prefix arr

    /// Was the ciphertext already plaintext? True if `head` starts with a
    /// known unencrypted magic. Caller passes the first 16 bytes.
    let looksLikePlaintext (head: byte[]) : bool =
        if head.Length = 0 then false
        else
            startsWith magicPng head
            || startsWith magicOgg head
            || startsWith magicJpg head
            || (head.Length >= 12 && startsWith magicRiff head && subArrayEq 8 4 magicWebp head)
            || (head.Length >= 8 && subArrayEq 4 4 magicM4a head)

    /// Single hex character -> 0..15. Raises on bad char.
    let private hexNibble (c: char) : int =
        match c with
        | '0' -> 0  | '1' -> 1  | '2' -> 2  | '3' -> 3
        | '4' -> 4  | '5' -> 5  | '6' -> 6  | '7' -> 7
        | '8' -> 8  | '9' -> 9
        | 'a' -> 10 | 'b' -> 11 | 'c' -> 12 | 'd' -> 13
        | 'e' -> 14 | 'f' -> 15
        | _   -> invalidArg "hex" (sprintf "non-hex char '%c'" c)

    /// Decode a 32-char hex string into a 16-byte array. The MV/MZ key
    /// is always presented as this exact shape in System.json.
    let decodeHexKey (hex: string) : byte[] =
        let cleaned = hex.Trim().ToLowerInvariant()
        if cleaned.Length <> 32 then
            invalidArg "hex" (sprintf "encryption key must be 32 hex chars, got %d" cleaned.Length)
        let bytes = Array.zeroCreate<byte> 16
        for i in 0 .. 15 do
            let hi = hexNibble cleaned.[2 * i]
            let lo = hexNibble cleaned.[2 * i + 1]
            bytes.[i] <- byte ((hi <<< 4) ||| lo)
        bytes

    /// XOR `buf` against `key` cyclically. Symmetric — encrypt == decrypt.
    let xorTransform (key: byte[]) (buf: byte[]) : byte[] =
        if key.Length = 0 then
            invalidArg "key" "XOR key must be non-empty"
        let n = buf.Length
        let out = Array.zeroCreate<byte> n
        let klen = key.Length
        for i in 0 .. n - 1 do
            out.[i] <- buf.[i] ^^^ key.[i % klen]
        out

    let isMvMagicHeader (head: byte[]) : bool =
        head.Length >= magicMvHeader.Length && startsWith magicMvHeader head

    let isMzMagicHeader (head: byte[]) : bool =
        head.Length >= magicMzHeader.Length && startsWith magicMzHeader head

    let isRgssadMagic (head: byte[]) : bool =
        head.Length >= magicRgssadPrefix.Length && startsWith magicRgssadPrefix head

    let isZipMagic (head: byte[]) : bool =
        head.Length >= 4
        && head.[0] = byte 'P'
        && head.[1] = byte 'K'
        && head.[2] = 0x03uy
        && head.[3] = 0x04uy

    let zeroFill (buf: byte[]) : unit =
        if not (isNull buf) then
            for i in 0 .. buf.Length - 1 do buf.[i] <- 0uy
