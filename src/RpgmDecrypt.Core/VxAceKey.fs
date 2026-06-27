namespace RpgmDecrypt.Core

/// Key derivation + payload decryption for RPG Maker VX Ace RGSSAD v3.
///
/// The algorithm is two distinct, well-defined steps:
//   1. **Filename decryption** uses a 16-byte-cycling-or-4-byte XOR key
///      that is derived as `(header_seed_LE_u32) * 9 + 3` from the first
///      4-byte little-endian word after the "RGSSAD\0\x03" header.
///   2. **Payload decryption** uses a per-entry 32-bit key (stored in
///      each entry record) that is then **mutated every 4 bytes**
///      during the byte stream via `tempKey = tempKey * 7 + 3`,
///      cycling only the first 4 bytes of the resulting ++integer.
///
/// Reference algorithm (clean-room re-implementation, not a copy):
///   uuksu/RPGMakerDecrypter (MIT, https://github.com/uuksu/RPGMakerDecrypter)
///     - RGSSADv3.cs:   master-key derivation + filename XOR
///     - RGSSAD.cs:     payload XOR with rotation
///
/// Notes for clean-room compliance (per CONTRIBUTING.md rule):
///   * The literal formulas `master = seed * 9 + 3` and
///     `tempKey = tempKey * 7 + 3` are reverse-engineered industry
///     facts — they have no expressive copyrightable form.
///   * We implement them afresh in F# rather than copy-pasting uuksu's
///     C# sample lines.
///   * Tests verify behaviour by exercising the real `.rgss3a` from
///     `F:\fr\g\HC_EP1\Game.rgss3a` against round-tripped bytes.
module VxAceKey =

    /// Master key derivation: read 4 LE bytes after the 8-byte header
    /// at `seedOffset`, then `masterKey = seed * 9 + 3`.
    let deriveMasterKey (buf: byte[]) (seedOffset: int) : uint32 =
        let seed =
            uint32 buf.[seedOffset]
            ||| (uint32 buf.[seedOffset + 1] <<< 8)
            ||| (uint32 buf.[seedOffset + 2] <<< 16)
            ||| (uint32 buf.[seedOffset + 3] <<< 24)
        seed * 9u + 3u

    /// XOR a u32 field (used for offset/size/per-entry-key/name_len).
    let decodeUInt32 (cipher: uint32) (key: uint32) : uint32 =
        cipher ^^^ key

    /// Decrypt a filename byte stream, cycling the 4-byte key per byte.
    let decodeFilename (cipher: byte[]) (masterKey: uint32) : string =
        let n = cipher.Length
        let out = Array.zeroCreate<byte> n
        let safe (b: byte) = if int b < 0 then byte (256 + int b) else b
        let keyBytes () =
            [| safe (byte masterKey)
               safe (byte (masterKey >>>  8))
               safe (byte (masterKey >>> 16))
               safe (byte (masterKey >>> 24)) |]
        let mutable j = 0
        for i in 0 .. n - 1 do
            let kb = keyBytes ()
            out.[i] <- cipher.[i] ^^^ kb.[j]
            j <- j + 1
            if j = 4 then j <- 0
        System.Text.Encoding.UTF8.GetString out

    /// Decrypt a file payload byte stream. Each 4 bytes read, the
    /// running `tempKey` is mutated by `tempKey = tempKey * 7 + 3` and
    /// the byte XOR index cycles back to 0. This is the well-known RGSS3
    /// stream cipher observed in every successful RPG Maker VX Ace
    /// shipped-game archive.
    let decodePayload (cipher: byte[]) (entryKey: uint32) : byte[] =
        let n = cipher.Length
        let out = Array.zeroCreate<byte> n
        let safe (b: byte) = if int b < 0 then byte (256 + int b) else b
        let mutable tempKey = entryKey
        let mutable kb =
            [| safe (byte tempKey)
               safe (byte (tempKey >>>  8))
               safe (byte (tempKey >>> 16))
               safe (byte (tempKey >>> 24)) |]
        let mutable j = 0
        for i in 0 .. n - 1 do
            out.[i] <- cipher.[i] ^^^ kb.[j]
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
