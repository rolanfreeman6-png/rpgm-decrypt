namespace RpgmDecrypt.Core

/// Top-level format dispatcher. For each candidate input file we
/// classify by content, dispatch to the right per-format module, and
/// produce an Outcome record.
module Dispatch =

    open System.IO

    let classify (absPath: string) : Format option =
        if not (File.Exists absPath) then None
        else
            let name = Path.GetFileName(absPath).ToLowerInvariant()
            let ext  = Path.GetExtension(absPath).ToLowerInvariant()
            let firstBytes =
                use s = File.OpenRead absPath
                let buf = Array.zeroCreate<byte> 16
                let n = s.Read(buf, 0, 16)
                if n < 16 then Array.zeroCreate<byte> n
                else buf
            // Quick exit by recognised extension first.
            match ext with
            | ".rgssad" ->
                if firstBytes.Length < 8 then Some XP   // can't tell yet
                else
                    match firstBytes.[7] with
                    | 0x01uy -> Some XP
                    | 0x02uy -> Some VX
                    | 0x03uy -> Some VXAce     // .rgssad carrying a v3 header
                    | _      -> Some XP        // legacy default
            | ".rgss2a" -> Some VX
            | ".rgss3a" -> Some VXAce
            | ".pak"    -> Some MZ
            | ".png_" | ".ogg_" | ".m4a_" -> Some MV
            | ".rpgmvp" | ".rpgmvo" | ".rpgmvm" -> Some MV
            // Plaintext PNG/OGG/M4A/WebP/JPG are still MV assets — by real
            // shipped-game definition. They are NOT encrypted, so MV.decrypt
            // returns the Plaintext outcome which Report.run treats as a
            // pass-through copy. Missing these meant walker filtered out
            // pass-through files entirely despite reporting them as MV.
            | ".png" | ".ogg" | ".m4a" | ".webp" | ".jpg" -> Some MV
            | _ ->
                // No recognised extension — try magic-byte inspection.
                if Crypto.isRgssadMagic firstBytes then
                    match firstBytes.[7] with
                    | 0x01uy -> Some XP
                    | 0x02uy -> Some VX
                    | 0x03uy -> Some VXAce
                    | _      -> Some XP
                elif Crypto.isZipMagic firstBytes then
                    Some MZ
                elif Crypto.isMvMagicHeader firstBytes then Some MV
                elif Crypto.isMzMagicHeader firstBytes then Some MZ
                else None

    /// Decrypt a single-file asset (MV/MZ individual encrypted file).
    /// Returns: (decrypted bytes, output kind string, was-decrypted bool).
    let decryptSingle (key: byte[]) (absPath: string) : Result<byte[] * string * bool, string> =
        try
            let bytes = File.ReadAllBytes absPath
            // One decrypt pass; derive both the output and the was-decrypted
            // flag from the single DecryptOutcome (previously decrypted twice).
            let out, kind, actuallyDecrypted =
                match Mv.decrypt key bytes with
                | Mv.Plaintext(k, b) -> b, k, false
                | Mv.Decrypted(k, b) -> b, k, true
                | Mv.Unsure b        -> b, "bin", true
            Ok(out, kind, actuallyDecrypted)
        with
        | ex -> Error ex.Message

    /// Decrypt a packed MZ archive (.pak). Returns a list of
    /// (relative output name, bytes, kind) tuples.
    let decryptArchive (key: byte[]) (absPath: string) :
        Result<(string * byte[] * string) list, string> =
        match Mz.openPak absPath with
        | Error Mz.NotAZipFile ->
            Error (sprintf "%s: not a ZIP / .pak archive" absPath)
        | Error (Mz.BadHeader msg) ->
            Error (sprintf "%s: bad zip header — %s" absPath msg)
        | Error (Mz.IOFailure ex) ->
            Error (sprintf "%s: I/O — %s" absPath ex.Message)
        | Ok z ->
            match Mz.decryptAll key z with
            | Error msg -> Error (sprintf "%s: %s" absPath msg)
            | Ok entries ->
                Ok (entries
                    |> List.map (fun e -> e.EntryName, e.Bytes, e.PlaintextKind))

    /// Convert a `.png_` style extension given the actual kind to a
    /// real output extension. Cleans up WebP-misnamed-as-PNG inputs.
    let chooseOutputExtension (inputExt: string) (kind: string) : string =
        match kind with
        | "png"  -> ".png"
        | "ogg"  -> ".ogg"
        | "m4a"  -> ".m4a"
        | "webp" -> ".webp"
        | "jpg"  -> ".jpg"
        | _ ->
            match inputExt with
            | ".png_"  -> ".png"
            | ".ogg_"  -> ".ogg"
            | ".m4a_"  -> ".m4a"
            | _        -> ".bin"
