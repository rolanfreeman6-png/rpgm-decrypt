namespace RpgmDecrypt.Core

/// RPG Maker XP `.rgssad` (version 1) archive walker.
///
/// Thin wrapper over the shared `RgssadCore` parser: XP differs from VX only by
/// the version byte (`0x01`) and the end-of-table sentinel (`name_len = 0`).
/// The full layout and algorithm are documented in RgssadCore.fs.
///
/// Payload is zlib-deflated; we expose the table of contents (offset/size per
/// entry) and leave inflate + Ruby Marshal handling to the caller's toolchain
/// (security posture — see docs/THEORY.md §8).
[<RequireQualifiedAccess>]
module Xp =

    type Entry = RgssadCore.Entry

    type ParseError =
        | ShortHeader
        | BadMagic
        | BadVersion of byte
        | Truncated

    let magicKey = RgssadCore.magicKey
    let xorDecodeName = RgssadCore.xorDecodeName

    let private toErr =
        function
        | RgssadCore.ShortHeader    -> ShortHeader
        | RgssadCore.BadMagic       -> BadMagic
        | RgssadCore.BadVersion b   -> BadVersion b
        | RgssadCore.Truncated      -> Truncated

    /// Parse an XP `.rgssad` table of contents. Returns entries + first-payload
    /// offset (XP terminates the table at the first `name_len = 0` record).
    let parse (buf: byte[]) : Result<Entry list * int, ParseError> =
        match RgssadCore.parse 0x01uy RgssadCore.NameLenZero buf with
        | Ok ok    -> Ok ok
        | Error e  -> Error(toErr e)

    let parseFile (path: string) : Result<Entry list * int, ParseError> =
        parse (System.IO.File.ReadAllBytes path)

    let readEntry = RgssadCore.readEntry
