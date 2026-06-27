namespace RpgmDecrypt.Core

/// Pure-data walker over the user's game directory.
///
/// Yields `DetectedFile` records for every input file whose extension or
/// magic bytes suggest an RPG Maker asset. Classification is delegated
/// to `Dispatch.classify` so the walker itself is stateless.
module Walk =

    open System.IO

    let candidateExtensions =
        [ ".rgssad"; ".rgss2a"; ".rgss3a"
          ".png_";  ".ogg_";  ".m4a_"
          ".rpgmvp"; ".rpgmvo"; ".rpgmvm"
          ".pak"
          ".png" ; ".ogg" ; ".m4a"; ".webp"; ".jpg" ]

    let private hasInterestingExtension (path: string) : bool =
        let ext = Path.GetExtension(path).ToLowerInvariant()
        candidateExtensions |> List.contains ext

    let walk (rootDir: string) : DetectedFile list =

        if not (Directory.Exists rootDir) then
            []
        else
            let acc = ResizeArray<DetectedFile>()
            for path in Directory.EnumerateFiles(rootDir, "*", SearchOption.AllDirectories) do
                if hasInterestingExtension path then
                    let info = FileInfo path
                    let size = info.Length
                    match Dispatch.classify path with
                    | Some fmt ->
                        let rel = Path.GetRelativePath(rootDir, path)
                        let detected : DetectedFile =
                            { AbsPath = path
                              RelPath = rel
                              SizeBytes = size
                              Format = fmt }
                        acc.Add detected
                    | None -> ()
            List.ofSeq acc

    let walkWithProgress (rootDir: string) (onProgress: string -> unit) : DetectedFile list =
        if not (Directory.Exists rootDir) then
            []
        else
            let acc = ResizeArray<DetectedFile>()
            let mutable visited = 0
            for path in Directory.EnumerateFiles(rootDir, "*", SearchOption.AllDirectories) do
                visited <- visited + 1
                onProgress (sprintf "visited %d" visited)
                if hasInterestingExtension path then
                    let info = FileInfo path
                    let size = info.Length
                    match Dispatch.classify path with
                    | Some fmt ->
                        let rel = Path.GetRelativePath(rootDir, path)
                        let detected : DetectedFile =
                            { AbsPath = path
                              RelPath = rel
                              SizeBytes = size
                              Format = fmt }
                        acc.Add detected
                    | None -> ()
            List.ofSeq acc
