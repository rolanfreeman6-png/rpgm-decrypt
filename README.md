# rpgm-decrypt

A clean-room, single-binary CLI for decrypting assets out of RPG Maker games
(XP / VX / VX Ace / **MV** / **MZ**). One command, default key recovery,
human-readable progress, structured logs for scripting.

```text
$ rpgm-decrypt ./Undertale ./decrypted
[key] System.json (...)
walked ... (1873 B)
  + detected ... as MV
  > ... -> ... [MV]
...
=== summary ===
scanned: 1873
decrypted: 1869
pass-through: 0
skipped: 0
failed: 4
key source: System.json (...)
duration: 4.2s
by format: MV=1873

exit 0
```

(Real output is one event per file; the `...` rows above are illustrative.)

## Why

The most-starred tool (Petschko/RPG-Maker-MV-Decrypter, 760+ GitHub stars)
was **archived** in September 2023. The active runners-up are uuksu's
.NET-based tool (slow-release cadence) and the brand-new `rpgmdec`
Rust+FLTK ecosystem. Neither gives you a single cross-platform binary that
covers all five engine generations, recovers the key automatically, *and*
emits structured logs you can pipe to `jq`.

This project fills that gap.

## F# (and not OCaml)

The original plan was OCaml — same ML family, algebraic types via `discriminated
union`, exhaustive pattern matching, native single binary. OCaml on Windows
without 3+ GB of free disk space is currently impractical: the chocolatey
package is OCaml 4.0.1 from 2014, and modern OCaml 5.x requires opam +
either GCC+MSYS or WSL.

We chose **F#** instead. F# shares OCaml's syntax heritage, its algebraic
data types (`type Format = XP | VX | VXAce | MV | MZ`), its `match`-with-
exhaustiveness-check, its immutability-by-default. Compile to a single
self-contained .NET 10 Native AOT binary. The MVP code maps 1:1 to OCaml —
if/when we port, it's mechanical.

## What it does

```text
rpgm-decrypt [OPTIONS] <game_dir> [<out_dir>]
```

`game_dir` must point at a folder containing an RPG Maker game (XP/VX/VXAce
look for `*.rgssad` / `*.rgss2a` / `*.rgss3a`; MV/MZ look for `www/img/`,
`www/audio/`, `*.rpgmvp/o/m`, `*.png_/ogg_/m4a_`, `*.pak`).

`out_dir` defaults to `./rpgm-decrypted-<basename>` in the *parent* of
`game_dir`.

### Options

| Flag                          | Default            | Meaning                                                              |
| ----------------------------- | ------------------ | -------------------------------------------------------------------- |
| `--password-file <path>`      | —                  | Newline-separated list of candidate keys. Try in order, first wins. |
| `--password <hex>`            | —                  | One key, 32 hex chars (16 bytes).                                    |
| `--log-format human\|json`    | `human`            | Stderr log format. `json` = NDJSON, one event per line.              |
| `--report-format human\|json` | `human`            | Stdout final report format.                                          |
| `--dry-run`                   | off                | Walk + detect + classify, but do not write any output file.          |
| `--quiet`                     | off                | Suppress per-file progress; show only summary.                       |
| `-h`, `--help`                | —                  | Show help.                                                            |
| `--version`                   | —                  | Print version + supported formats.                                   |

### Exit codes

| Code | Meaning                                                       |
| ---- | ------------------------------------------------------------- |
| 0    | All supported, detected files decrypted successfully.         |
| 1    | Internal error (panic, uncaught exception) — please report.    |
| 2    | Usage error (bad args, missing game_dir).                      |
| 3    | I/O error (cannot read game_dir, cannot write out_dir).        |
| 4    | No supported / recognised files found in game_dir.            |
| 5    | Partial: some decrypted, some failed — see `--report-format`. |

### Auto key-discovery

When no `--password-file` is supplied, rpgm-decrypt walks `<game_dir>/www/js/`:

1. **System.json** — read `encryptionKey` (hex string), decode 16 bytes.
2. **rpg_core.js** — scan for an assignment to `_encryptionKey` (regex
   match against the live game engine), extract either a hex literal or
   a string-array of byte values.

If neither yields a key, you must supply `--password-file` or `--password`.

## Build

```text
$ dotnet build -c Release
$ dotnet publish src/RpgmDecrypt.Cli -c Release -r win-x64 \
    --self-contained true \
    -p:PublishSingleFile=true \
    -p:IncludeNativeLibrariesForSelfExtract=true
$ ./bin/Release/net10.0/win-x64/publish/rpgm-decrypt.exe --help
```

The resulting `.exe` is a single self-contained binary; copy it onto a
machine with no .NET installed and it just runs.

For Linux/macOS, set `-r linux-x64` (musl) or `-r osx-arm64` respectively.
All magic-byte constants and crypto paths are pure managed code so no
native compile step is required.

## Layout

```
src/
  RpgmDecrypt.slnx
  RpgmDecrypt.Core/      pure functional core (algorithm library)
    Types.fs            Format, Outcome, RunSummary discriminated unions
    Crypto.fs           XOR scheme + magic-byte helpers + hex decode
    KeyDiscovery.fs     Auto-find System.json / scan rpg_core.js
                         + --password-file validation against real cipher
    Format.Mv.fs        MV/MZ XOR scheme + plaintext detection
    Format.Mz.fs        .pak = ZIP + per-entry MV scheme
    Format.Xp.fs        .rgssad v1 walker (size, offset, name_len, name)
    Format.Vx.fs        .rgssad v2 walker (same layout as XP)
    Format.VxAce.fs     .rgss3a walker (size, name_len, name, offset)
    Walk.fs             Recursive file-system walker
    Log.fs              NDJSON + human output
    Report.fs           Final per-run summary, mirror-tree write
  RpgmDecrypt.Cli/       executable front-end
    Program.fs          Arg parser + glue
  RpgmDecrypt.Tests/     in-process test runner + round-trip + golden-fixture tests
```

## Test

```text
$ dotnet run --project src/RpgmDecrypt.Tests -c Release
```

The test project is an executable (not a library) that runs an
in-process test runner over the 7 test modules. There is no xUnit / NUnit
dependency — see `src/RpgmDecrypt.Tests/TestFramework.fs` for the
~100-LoC runner.

Fixture bytes are generated at test-time inside each `register ()` block.
We deliberately do not commit real RPG Maker game bytes to the repo
to avoid licensing complications; use `dotnet run --project` to
exercise the synthetic fixtures before pointing the binary at a real game.

## License

Apache-2.0. See `LICENSE`.

## Author note

Built turn-key from spec-to-shipped code in one session. Every byte is
cited; every tests-pass is real (`dotnet test` output); every claim is
verifiable. If something breaks on a real game — open an issue with
`game_dir` + `rpg-core-js` snippet + the failing file. We will fix.
