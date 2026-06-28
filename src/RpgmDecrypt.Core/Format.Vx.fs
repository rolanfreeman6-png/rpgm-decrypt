namespace RpgmDecrypt.Core

/// RPG Maker VX archive walker — extension `.rgssad` with version byte `0x02`,
/// or `.rgss2a`.
///
/// Thin wrapper over the shared `RgssadCore` parser: VX differs from XP only by
/// the version byte (`0x02`) and the end-of-table sentinel (`size = 0 &&
/// name_len = 0`). The full layout and the negative-`name_len` guard live in
/// RgssadCore.fs, so XP and VX cannot drift apart.
[<RequireQualifiedAccess>]
module Vx =

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

    let parse (buf: byte[]) : Result<Entry list * int, ParseError> =
        match RgssadCore.parse 0x02uy RgssadCore.SizeAndNameZero buf with
        | Ok ok    -> Ok ok
        | Error e  -> Error(toErr e)

    let parseFile (path: string) : Result<Entry list * int, ParseError> =
        parse (System.IO.File.ReadAllBytes path)

    let readEntry = RgssadCore.readEntry
