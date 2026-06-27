namespace RpgmDecrypt.Core

/// Logging sinks.
///
/// Two formats:
///   * `Human` — ANSI-friendly progress lines + summary.
///   * `Json`  — newline-delimited JSON for piping into `jq`.
module Log =

    type Format = Human | Json

    type Event =
        | Walked      of path: string * size: int64
        | Detected    of path: string * format: string
        | KeyFound    of source: string
        | Decrypt     of inputPath: string * outputPath: string * format: string
        | PassThrough of path: string
        | Skipped     of path: string * reason: string
        | Failed      of path: string * reason: string
        | Summary     of RunSummary

    let private escape (s: string) : string =
        let sb = System.Text.StringBuilder(s.Length + 8)
        for c in s do
            match c with
            | '\\' -> sb.Append("\\\\") |> ignore
            | '"'  -> sb.Append("\\\"") |> ignore
            | '\n' -> sb.Append("\\n") |> ignore
            | '\r' -> sb.Append("\\r") |> ignore
            | '\t' -> sb.Append("\\t") |> ignore
            | c when int c < 32 -> sb.Append(' ') |> ignore
            | c    -> sb.Append(c) |> ignore
        sb.ToString()

    let private hrFmt =
        function
        | XP -> "XP" | VX -> "VX" | VXAce -> "VXAce" | MV -> "MV" | MZ -> "MZ"

    let private summaryToJson (s: RunSummary) : string =
        let perFmt =
            s.PerFormat
            |> Map.toList
            |> List.map (fun (k, v) -> sprintf "\"%s\":%d" (hrFmt k) v)
            |> String.concat ","
        sprintf
            """{"kind":"summary","started":"%s","finished":"%s","scanned":%d,"decrypted":%d,"passthrough":%d,"skipped":%d,"failed":%d,"key_source":"%s","per_format":{%s}}"""
            (escape (s.StartedAt.ToString("o")))
            (escape (s.FinishedAt.ToString("o")))
            s.InputsScanned
            s.DecryptedCount
            s.PassedThroughCount
            s.SkippedCount
            s.FailedCount
            (escape s.KeySource)
            perFmt

    let private eventToJson (e: Event) : string =
        match e with
        | Walked(p, sz) -> sprintf """{"kind":"walked","path":"%s","size":%d}""" (escape p) sz
        | Detected(p, fmt_) -> sprintf """{"kind":"detected","path":"%s","format":"%s"}""" (escape p) (escape fmt_)
        | KeyFound src     -> sprintf """{"kind":"key_found","source":"%s"}""" (escape src)
        | Decrypt(i, o, fmt_) -> sprintf """{"kind":"decrypt","input":"%s","output":"%s","format":"%s"}""" (escape i) (escape o) (escape fmt_)
        | PassThrough p    -> sprintf """{"kind":"passthrough","path":"%s"}""" (escape p)
        | Skipped(p, r)    -> sprintf """{"kind":"skipped","path":"%s","reason":"%s"}""" (escape p) (escape r)
        | Failed(p, r)     -> sprintf """{"kind":"failed","path":"%s","reason":"%s"}""" (escape p) (escape r)
        | Summary s        -> summaryToJson s

    let private humanSummary (s: RunSummary) : string =
        let dur = s.FinishedAt - s.StartedAt
        let perFmtLine =
            s.PerFormat
            |> Map.toList
            |> List.map (fun (k, v) -> sprintf "%s=%d" (hrFmt k) v)
            |> String.concat " "
        sprintf
            "scanned: %d\ndecrypted: %d\npass-through: %d\nskipped: %d\nfailed: %d\nkey source: %s\nduration: %.2fs\nby format: %s"
            s.InputsScanned
            s.DecryptedCount
            s.PassedThroughCount
            s.SkippedCount
            s.FailedCount
            s.KeySource
            dur.TotalSeconds
            perFmtLine

    /// Emit one event to STDERR using chosen format.
    let emit (fmt: Format) (e: Event) : unit =
        match fmt with
        | Human ->
            match e with
            | Walked(p, sz)        -> eprintfn "walked %s (%d B)" p sz
            | Detected(p, fmt_)    -> eprintfn "  + detected %s as %s" p fmt_
            | KeyFound src         -> eprintfn "[key] %s" src
            | Decrypt(i, o, fmt_)  -> eprintfn "  > %s -> %s [%s]" i o fmt_
            | PassThrough p        -> eprintfn "  = %s (already plaintext)" p
            | Skipped(p, r)        -> eprintfn "  - skipped %s (%s)" p r
            | Failed(p, r)         -> eprintfn "  x failed %s (%s)" p r
            | Summary s            -> eprintfn "\n=== summary ===\n%s" (humanSummary s)
        | Json  -> eprintfn "%s" (eventToJson e)
