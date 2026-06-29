namespace RpgmDecrypt.Core

open System

/// RPG Maker engine generation. Discriminator for the format dispatcher.
type Format =
    | XP     // RPG Maker XP, archive: .rgssad (version 0x01)
    | VX     // RPG Maker VX, archive: .rgssad (version 0x02) or .rgss2a
    | VXAce  // RPG Maker VX Ace, archive: .rgss3a (version 0x03)
    | MV     // RPG Maker MV, individual XOR-encrypted assets (.png_, .ogg_, .m4a_, .rpgmvp/o/m)
    | MZ     // RPG Maker MZ, .pak ZIP containing same MV-scheme encrypted assets

module Format =
    let toString =
        function
        | XP -> "XP"
        | VX -> "VX"
        | VXAce -> "VXAce"
        | MV -> "MV"
        | MZ -> "MZ"

    let ofString =
        function
        | "XP"     -> Some XP
        | "VX"     -> Some VX
        | "VXAce"  -> Some VXAce
        | "MV"     -> Some MV
        | "MZ"     -> Some MZ
        | _        -> None

/// A file we have inspected while walking the user's game directory.
type DetectedFile =
    { AbsPath: string
      RelPath: string
      SizeBytes: int64
      Format: Format }

/// What we did with one input file. Tagged union so the orchestrator
/// can pattern-match on outcome without scattering bool flags.
type Outcome =
    /// Decrypted from cipher to plain file and wrote to disk.
    | Decrypted of relOutPath: string * bytesWritten: int64 * format: Format
    /// Cipher / key did not apply (file already plaintext); copied through.
    | PassedThrough of relOutPath: string * format: Format
    /// Recognised format, but skipped for a stated reason (size, scheme mismatch).
    | Skipped of inputRelPath: string * reason: string
    /// Recognised format, decryption attempted, wrote a `.broken` file
    /// alongside the intended output so the caller can review what failed.
    | Failed of inputRelPath: string * reason: string

/// End-of-run numbers. The CLI emits JSON for this so scripts can parse it.
type RunSummary =
    { StartedAt: DateTime
      FinishedAt: DateTime
      InputsScanned: int
      DecryptedCount: int
      PassedThroughCount: int
      SkippedCount: int
      FailedCount: int
      PerFormat: Map<Format, int>
      KeySource: string
      Errors: (string * string) list }

module RunSummary =
    let empty (now: DateTime) : RunSummary =
        { StartedAt = now
          FinishedAt = now
          InputsScanned = 0
          DecryptedCount = 0
          PassedThroughCount = 0
          SkippedCount = 0
          FailedCount = 0
          PerFormat = Map.empty
          KeySource = "none"
          Errors = [] }

    let private bumpFmt (s: RunSummary) (fmt: Format) : RunSummary =
        let m =
            match Map.tryFind fmt s.PerFormat with
            | Some n -> Map.add fmt (n + 1) s.PerFormat
            | None   -> Map.add fmt 1 s.PerFormat
        { s with PerFormat = m }

    let tally outcome (s: RunSummary) : RunSummary =
        match outcome with
        | Decrypted(_, _, fmt) ->
            let s2 = { s with DecryptedCount = s.DecryptedCount + 1 }
            bumpFmt s2 fmt
        | PassedThrough(_, fmt) ->
            let s2 = { s with PassedThroughCount = s.PassedThroughCount + 1 }
            bumpFmt s2 fmt
        | Skipped(_, _) ->
            { s with SkippedCount = s.SkippedCount + 1 }
        | Failed(_, _) ->
            { s with FailedCount = s.FailedCount + 1 }
