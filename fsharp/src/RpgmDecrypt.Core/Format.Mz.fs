namespace RpgmDecrypt.Core

/// MZ `.pak` archive extraction.
///
/// An RPG Maker MZ game ships assets bundled into a single
/// `<game>/www/packed_<hash>.pak` file. Internals:
///
///   * The `.pak` is a plain ZIP archive (no ZIP-level encryption).
///   * Each ZIP entry's payload is *individually* encrypted using the
///     same MV key + XOR scheme. So we open the ZIP, iterate entries,
///     and run each payload through `Mv.decrypt`.
///
/// Reference: https://rpgmakerweb.com public docs; ZIP spec PKWARE
/// APPNOTE.TXT 6.3.4 (cross-checked via System.IO.Compression source
/// which is .NET-standard).
module Mz =

    open System
    open System.IO
    open System.IO.Compression

    open Crypto

    type EntryResult =
        { EntryName: string
          PlaintextKind: string
          Bytes: byte[] }

    type OpenError =
        | NotAZipFile
        | BadHeader of msg: string
        | IOFailure of exn: exn

    /// Open a `.pak` file as a ZIP archive.
    let openPak (path: string) : Result<ZipArchive, OpenError> =
        try
            let bytes = File.ReadAllBytes path
            let head = Array.zeroCreate<byte> (min 4 bytes.Length)
            Array.Copy(bytes, head, head.Length)
            if not (isZipMagic head) then
                Error NotAZipFile
            else
                let stream = new MemoryStream(bytes, writable = false)
                let z = new ZipArchive(stream, ZipArchiveMode.Read, leaveOpen = false)
                Ok z
        with
        | :? IOException as ex -> Error(IOFailure ex)
        | :? InvalidDataException as ex -> Error(BadHeader ex.Message)
        | ex -> Error(IOFailure ex)

    /// Iterate every entry, decrypt each one with `key`. Order preserved.
    let decryptAll (key: byte[]) (z: ZipArchive) : Result<EntryResult list, string> =
        try
            let acc = ResizeArray<EntryResult>()
            for entry in z.Entries do
                if entry.FullName.EndsWith "/" then () // directory marker, skip
                else
                    use s = entry.Open()
                    use ms = new MemoryStream()
                    s.CopyTo(ms)
                    let cipher = ms.ToArray()
                    let plain, kind = Mv.decryptBytes key cipher
                    acc.Add({ EntryName = entry.FullName; PlaintextKind = kind; Bytes = plain })
            Ok (List.ofSeq acc)
        with
        | ex -> Error ex.Message
