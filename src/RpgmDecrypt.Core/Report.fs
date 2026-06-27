namespace RpgmDecrypt.Core

/// Top-level orchestrator. Walks the user's game directory, classifies
/// every file, applies the right decryption, and writes a mirror of the
/// input tree under `outDir`. Builds a `RunSummary` for the CLI to emit.
module Report =

    open System
    open System.IO

    /// Mirror-directory write. Creates parent dirs as needed.
    let private writeAllBytes (path: string) (bytes: byte[]) : unit =
        let dir = Path.GetDirectoryName path
        if not (String.IsNullOrEmpty dir) && not (Directory.Exists dir) then
            Directory.CreateDirectory dir |> ignore
        File.WriteAllBytes(path, bytes)

    let private stripEncryptionExtension (path: string) : string =
        // .png_ → .png, .ogg_ → .ogg, .m4a_ → .m4a.
        // (Earlier version dropped the trailing underscore but kept the
        // suffix letter, producing ".pngg". Fixed to drop the underscore
        // only.)
        if path.EndsWith "_" then path.Substring(0, path.Length - 1)
        else path

    let private renameByKind (relPath: string) (kind: string) : string =
        match kind with
        | "png" | "ogg" | "m4a" -> stripEncryptionExtension relPath
        | "webp" ->
            let dir  = Path.GetDirectoryName relPath
            let stem = Path.GetFileNameWithoutExtension relPath
            let ext  = "." + kind
            if String.IsNullOrEmpty dir then stem + ext
            else Path.Combine(dir, stem + ext)
        | _ -> relPath

    type Config =
        { GameDir: string
          OutDir: string
          Key: byte[]
          KeySource: string
          DryRun: bool
          OnEvent: Log.Event -> unit }

    let private copyThrough (src: string) (dst: string) : unit =
        // Mirror writeAllBytes: ensure parent dir is created first.
        let dir = Path.GetDirectoryName dst
        if not (String.IsNullOrEmpty dir) && not (Directory.Exists dir) then
            Directory.CreateDirectory dir |> ignore
        File.Copy(src, dst, overwrite = true)

    /// RXSS3 (RPG Maker VX Ace) real-life path: load archive bytes once,
    /// parse TOC, decode every payload using per-entry rotation key, write
    /// each entry mirroring its encrypted name into cfg.OutDir. Errors on
    /// individual entries do not abort the whole archive.
    let private extractVxAceArchive (archiveBytes: byte[]) (dRelPath: string) (dAbsPath: string) (cfg: Config) (summary: RunSummary byref) =
        match VxAce.parse archiveBytes with
        | Error parseErr ->
            let msg = sprintf "%A" parseErr
            summary <- RunSummary.tally (Failed(dRelPath, msg)) summary
            cfg.OnEvent (Log.Failed(dAbsPath, msg))
        | Ok entries ->
            let mutable failedHere = false
            for e in entries do
                try
                    let cipherSlice = VxAce.readEntry archiveBytes e
                    let plain = VxAce.decryptPayload e cipherSlice
                    let outputRel =
                        e.Name.Replace('\\', Path.DirectorySeparatorChar)
                           .Replace('/', Path.DirectorySeparatorChar)
                    let outputPath = Path.Combine(cfg.OutDir, outputRel)
                    if not cfg.DryRun then
                        let dir = Path.GetDirectoryName outputPath
                        if not (String.IsNullOrEmpty dir) && not (Directory.Exists dir) then
                            Directory.CreateDirectory dir |> ignore
                        File.WriteAllBytes(outputPath, plain)
                    summary <- RunSummary.tally (Decrypted(outputRel, int64 plain.Length, VXAce)) summary
                    cfg.OnEvent (Log.Decrypt(dAbsPath, outputPath, "VXAce"))
                with | ex ->
                    failedHere <- true
                    summary <- RunSummary.tally (Failed(e.Name, sprintf "decode error: %s" ex.Message)) summary
                    cfg.OnEvent (Log.Failed(dAbsPath, sprintf "decode error on %s" e.Name))
            if not failedHere then
                let manifestPath = Path.Combine(cfg.OutDir, dRelPath + ".entries.txt")
                if not cfg.DryRun then
                    let txt = entries
                             |> List.map (fun e -> sprintf "%d\t%s\toffset=%d\tsize=%d" e.Index e.Name e.Offset e.Size)
                             |> String.concat "\n"
                    writeAllBytes manifestPath (System.Text.Encoding.UTF8.GetBytes txt)
                summary <- RunSummary.tally (PassedThrough(manifestPath, VXAce)) summary
                cfg.OnEvent (Log.Decrypt(dAbsPath, manifestPath, "VXAce"))
            ()

    let run (cfg: Config) : RunSummary =
        let now0 = DateTime.UtcNow
        let mutable summary = RunSummary.empty now0
        cfg.OnEvent (Log.KeyFound cfg.KeySource)
        let detected = Walk.walk cfg.GameDir
        summary <- { summary with InputsScanned = List.length detected; KeySource = cfg.KeySource }
        for d in detected do
            cfg.OnEvent (Log.Walked(d.AbsPath, d.SizeBytes))
            cfg.OnEvent (Log.Detected(d.AbsPath, Format.toString d.Format))
            let outRel = renameByKind d.RelPath (match d.Format with MV -> "bin" | MZ -> "bin" | _ -> "bin")
            let outAbs = Path.Combine(cfg.OutDir, outRel)
            match d.Format with
            | MV ->
                match Dispatch.decryptSingle cfg.Key d.AbsPath with
                | Ok(bytes, kind, wasDecrypted) ->
                    if wasDecrypted then
                        let realKindOut = renameByKind outRel kind
                        let realOutAbs  = Path.Combine(cfg.OutDir, realKindOut)
                        if not cfg.DryRun then writeAllBytes realOutAbs bytes
                        summary <- RunSummary.tally (Decrypted(realKindOut, int64 bytes.Length, MV)) summary
                        cfg.OnEvent (Log.Decrypt(d.AbsPath, realOutAbs, "MV"))
                    else
                        if not cfg.DryRun then copyThrough d.AbsPath outAbs
                        summary <- RunSummary.tally (PassedThrough(outRel, MV)) summary
                        cfg.OnEvent (Log.PassThrough d.AbsPath)
                | Error msg ->
                    let brokenPath = outAbs + ".broken"
                    if not cfg.DryRun then writeAllBytes brokenPath [||]
                    summary <- RunSummary.tally (Failed(d.RelPath, msg)) summary
                    cfg.OnEvent (Log.Failed(d.AbsPath, msg))

            | MZ ->
                match Dispatch.decryptArchive cfg.Key d.AbsPath with
                | Ok entries ->
                    let dirPart = Path.GetDirectoryName outRel
                    let safeDir = if String.IsNullOrEmpty dirPart then "." else dirPart
                    for (entryName, bytes, kind) in entries do
                        let entryOutRel =
                            Path.Combine(safeDir, entryName)
                            |> renameByKind kind
                        let entryOutAbs = Path.Combine(cfg.OutDir, entryOutRel)
                        if not cfg.DryRun then writeAllBytes entryOutAbs bytes
                        summary <- RunSummary.tally (Decrypted(entryOutRel, int64 bytes.Length, MZ)) summary
                        cfg.OnEvent (Log.Decrypt(d.AbsPath, entryOutAbs, "MZ"))
                | Error msg ->
                    summary <- RunSummary.tally (Failed(d.RelPath, msg)) summary
                    cfg.OnEvent (Log.Failed(d.AbsPath, msg))

            | XP ->
                match Xp.parseFile d.AbsPath with
                | Ok (entries, _) ->
                    let manifestPath = Path.Combine(cfg.OutDir, d.RelPath + ".entries.txt")
                    if not cfg.DryRun then
                        let txt = entries
                                 |> List.map (fun e -> sprintf "%d\t%s\toffset=%d\tsize=%d" e.Index e.Name e.Offset e.Size)
                                 |> String.concat "\n"
                        writeAllBytes manifestPath (System.Text.Encoding.UTF8.GetBytes txt)
                    summary <- RunSummary.tally (PassedThrough(manifestPath, XP)) summary
                    cfg.OnEvent (Log.Decrypt(d.AbsPath, manifestPath, "XP"))
                | Error parseErr ->
                    let msg = sprintf "%A" parseErr
                    summary <- RunSummary.tally (Failed(d.RelPath, msg)) summary
                    cfg.OnEvent (Log.Failed(d.AbsPath, msg))

            | VX ->
                match Vx.parseFile d.AbsPath with
                | Ok (entries, _) ->
                    let manifestPath = Path.Combine(cfg.OutDir, d.RelPath + ".entries.txt")
                    if not cfg.DryRun then
                        let txt = entries
                                 |> List.map (fun e -> sprintf "%d\t%s\toffset=%d\tsize=%d" e.Index e.Name e.Offset e.Size)
                                 |> String.concat "\n"
                        writeAllBytes manifestPath (System.Text.Encoding.UTF8.GetBytes txt)
                    summary <- RunSummary.tally (PassedThrough(manifestPath, VX)) summary
                    cfg.OnEvent (Log.Decrypt(d.AbsPath, manifestPath, "VX"))
                | Error parseErr ->
                    let msg = sprintf "%A" parseErr
                    summary <- RunSummary.tally (Failed(d.RelPath, msg)) summary
                    cfg.OnEvent (Log.Failed(d.AbsPath, msg))

            | VXAce ->
                let mutable archiveBytes : byte[] = [||]
                let mutable archiveIoFailed = false
                try
                    archiveBytes <- File.ReadAllBytes d.AbsPath
                with | ex ->
                    archiveIoFailed <- true
                    summary <- RunSummary.tally (Failed(d.RelPath, sprintf "I/O during open: %s" ex.Message)) summary
                    cfg.OnEvent (Log.Failed(d.AbsPath, sprintf "I/O during open: %s" ex.Message))
                if (not archiveIoFailed) && archiveBytes.Length <> 0 then
                    extractVxAceArchive archiveBytes d.RelPath d.AbsPath cfg &summary

        let now1 = DateTime.UtcNow
        summary <- { summary with FinishedAt = now1 }
        summary
