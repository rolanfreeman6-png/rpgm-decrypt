namespace RpgmDecrypt.Core

/// MV/MZ individual-asset decryption.
///
/// Both MV (`.png_` / `.ogg_` / `.m4a_` / `.rpgmvp/o/m`) and MZ (entries
/// inside a `.pak` ZIP) share one bytewise XOR scheme:
///
///     cipher[i] = plain[i] XOR key[i MOD keyLength]
///
/// Symmetric property: applying the XOR twice on the same byte stream
/// returns to the original. So one function does both directions.
///
/// Reference: https://rpgmakerweb.com public docs, cross-checked against
/// the algorithm in uuksu/RPGMakerDecrypter (MIT) — used as reference
/// only, never copied. This file is a clean-room reimplementation.
module Mv =

    open Crypto

    /// Try to decrypt a single MV/MZ asset. Returns either:
    ///   * Decrypted plaintext bytes + a label of the detected output
    ///     format (PNG/OGG/M4A/WebP/JPG) so the caller can name the file
    ///     appropriately — important for WebP support where the input
    ///     extension is `.png_` but the output must be `.webp` to be
    ///     openable (Petschko issue #40).
    ///   * A failure reason otherwise.
    type DecryptOutcome =
        | Plaintext of kind: string * bytes: byte[]
        | Decrypted of kind: string * bytes: byte[]
        | Unsure    of bytes: byte[]  // XOR applied but plaintext magic not found

    /// The five recognised plaintext formats we know how to label.
    type PlaintextKind =
        | Png
        | Ogg
        | M4a
        | Webp
        | Jpg
        | Unknown

    let private classifyPlaintext (head: byte[]) : PlaintextKind =
        if head.Length = 0 then Unknown
        elif startsWith magicPng head then Png
        elif startsWith magicOgg head then Ogg
        elif head.Length >= 8 && subArrayEq 4 4 magicM4a head then M4a
        elif head.Length >= 12 && startsWith magicRiff head && subArrayEq 8 4 magicWebp head
            then Webp
        elif startsWith magicJpg head then Jpg
        else Unknown

    let plaintextKindToString =
        function
        | Png     -> "png"
        | Ogg     -> "ogg"
        | M4a     -> "m4a"
        | Webp    -> "webp"
        | Jpg     -> "jpg"
        | Unknown -> "bin"

    /// Decrypt a buffer that we believe is MV/MZ-style XOR-encrypted.
    /// If the buffer is already plaintext-flavoured, returns Plaintext
    /// (no XOR pass, just an identity copy — saves CPU on unencrypted
    /// PNGs often shipped alongside `*.png_`).
    let decrypt (key: byte[]) (cipher: byte[]) : DecryptOutcome =
        if key.Length = 0 then
            invalidArg "key" "MV key must not be empty"
        if cipher.Length = 0 then
            Plaintext("bin", cipher) // empty file — nothing to detect, pass through
        elif looksLikePlaintext cipher then
            let k = classifyPlaintext cipher
            Plaintext(plaintextKindToString k, cipher)
        else
            let plain = xorTransform key cipher
            let k = classifyPlaintext plain
            if k = Unknown then
                Unsure plain
            else
                Decrypted(plaintextKindToString k, plain)

    /// Song-extension / audio handlers use the same scheme;
    /// we centralise the call here so Mv and Mz paths agree.
    let decryptBytes (key: byte[]) (cipher: byte[]) : byte[] * string =
        match decrypt key cipher with
        | Plaintext(kind, bytes) -> bytes, kind
        | Decrypted(kind, bytes) -> bytes, kind
        | Unsure(bytes)          -> bytes, "bin"
