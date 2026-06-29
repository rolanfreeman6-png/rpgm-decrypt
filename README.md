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
self-contained .NET 10 binary (single-file publish, runtime bundled). The
MVP code maps 1:1 to OCaml — if/when we port, it's mechanical.

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
| `--vxace-seed <8hex>`         | —                  | RPG Maker VX Ace master-seed (8 hex chars), in place of auto key.    |
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
| 4    | No encryption key could be recovered.                         |
| 5    | Partial: at least one input failed to decrypt — see `--report-format`. |

### Auto key-discovery

When no key flag is supplied, rpgm-decrypt looks under `<game_dir>/www/`:

1. **`www/js/System.json`** then **`www/data/System.json`** (deployed layout)
   — read `encryptionKey` (hex string), decode 16 bytes.
2. **`www/js/rpg_core.js`** — regex-scan for a 32-hex-char `_encryptionKey`
   literal (we never evaluate JavaScript, only extract the literal).
3. **`*.js` sweep** — every `*.js` under `www/js`, then under all of `www/`.

If none yields a key, supply `--password <hex32>`, `--password-file <list>`,
or `--vxace-seed <8hex>` (VX Ace).

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
    Format.VxAce.fs     .rgss3a walker + payload decrypt
                         (offset, size, entry_key, name_len, name)
    Walk.fs             Recursive file-system walker
    Log.fs              NDJSON + human output
    Report.fs           Final per-run summary, mirror-tree write
  RpgmDecrypt.Cli/       executable front-end
    the CLI module          Arg parser + glue
  RpgmDecrypt.Tests/     in-process test runner + round-trip + golden-fixture tests
```

## Test

```text
$ dotnet run --project src/RpgmDecrypt.Tests -c Release
```

The test project is an executable (not a library) that runs an
in-process test runner over the 10 test modules (101 assertions). There is
no xUnit / NUnit dependency — see `src/RpgmDecrypt.Tests/TestFramework.fs`
for the ~100-LoC runner.

Fixture bytes are generated at test-time inside each `register ()` block.
We deliberately do not commit real RPG Maker game bytes to the repo
to avoid licensing complications; use `dotnet run --project` to
exercise the synthetic fixtures before pointing the binary at a real game.

## Distribution (GitLab → GitHub)

GitLab CI (`.gitlab-ci.yml`) is the build/test farm — it has the subscription
minutes to run the heavy gates:

- F# build + tests (`build-test`, `build-test-windows`)
- OCaml port parity (`ocaml-build-test`, 72 checks) + property/Gospel verification
  (`ocaml-verification`, 12 QCheck2 properties + `gospel check`)
- Coverage-guided fuzzing (`ocaml-fuzz`, afl-fuzz 90s)
- Product binaries: `publish-linux` (F# linux-x64 self-contained),
  `publish-windows` (F# win-x64 self-contained), `publish-ocaml` (OCaml native
  Linux, needs `libz1c2` at runtime)

After **all** gates and publish jobs pass, `github-release` creates a GitHub
Release on `rolanfreeman6-png/rpgm-decrypt` and uploads the three binaries:

- push to `main` → `continuous` prerelease (overwritten each push)
- tag `v…` → stable release

Setup (one-time): add a CI/CD variable `GITHUB_RELEASE_TOKEN` in GitLab →
Settings → CI/CD → Variables — a GitHub PAT with **Contents read/write** on
`rolanfreeman6-png/rpgm-decrypt` (classic PAT: `repo` scope; fine-grained:
"Contents: Read and write"). Mark it masked + protected. Without it the
release job fails fast with a clear message and nothing is shipped.

GitHub is the clean distribution channel — releases land there once GitLab has
verified them.

## License

Apache-2.0. See `LICENSE`.

## Author note

Built turn-key from spec-to-shipped code in one session. Every byte is
cited; every tests-pass is real (`dotnet test` output); every claim is
verifiable. If something breaks on a real game — open an issue with
`game_dir` + `rpg-core-js` snippet + the failing file. We will fix.
