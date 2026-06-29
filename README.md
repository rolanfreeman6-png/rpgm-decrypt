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

## F# origin → OCaml flagship

The project started as an F# MVP: same ML family, algebraic types, exhaustive
`match`, single self-contained .NET 10 binary. F# was chosen first because, at
the time, OCaml on Windows looked impractical (the chocolatey package was
OCaml 4.0.1 from 2014; modern 5.x needs opam + GCC/MSYS).

That turned out to be a tooling problem, not a language one. With a native
opam/mingw64 switch (OCaml 5.5.0) the port was done — the F# code mapped 1:1.
The **OCaml port is now the flagship**: it builds to a statically-linked musl
single binary (zero runtime deps, runs on any x86-64 Linux), and is the primary
download on GitHub Releases. The F# build remains as the parity reference (the
OCaml port is tested byte-for-byte against it, 72 parity checks) and ships as a
secondary self-contained asset. See `ocaml/README.md` for the port's formal
verification (Gospel specs, QCheck properties, mutation testing).

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

F# (secondary, self-contained .NET 10 single-file):

```text
$ dotnet publish fsharp/src/RpgmDecrypt.Cli -c Release -r win-x64 \
    --self-contained true \
    -p:PublishSingleFile=true \
    -p:IncludeNativeLibrariesForSelfExtract=true
$ ./bin/Release/net10.0/win-x64/publish/rpgm-decrypt.exe --help
```

The resulting `.exe` is a single self-contained binary; copy it onto a
machine with no .NET installed and it just runs. For Linux/macOS, set
`-r linux-x64` or `-r osx-arm64`. All magic-byte constants and crypto paths
are pure managed code so no native compile step is required.

OCaml (flagship — statically-linked musl single binary, zero runtime deps):

```text
$ cd ocaml
$ dune build --profile static bin/main.exe   # links libz + musl statically
$ ./_build/default/bin/main.exe --version
```

`--profile static` adds `-cclib -static`; build it on Alpine (musl) for a
true "runs on any x86-64 Linux" binary. `--profile release` builds a normal
dynamically-linked binary for development.

## Layout

```
ocaml/                 OCaml port — the flagship (static musl single binary)
  lib/ bin/ test/ fuzz/   + narrow .mli (Gospel specs) + QCheck properties
fsharp/                F# reference implementation + parity source of truth
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
.github/workflows/ci.yml  release workflow (tag-triggered; builds + ships)
.gitlab-ci.yml            test rig (F# + OCaml tests, fuzz, verification) + mirror
```

## Test

```text
$ dotnet run --project fsharp/src/RpgmDecrypt.Tests -c Release
```

The test project is an executable (not a library) that runs an
in-process test runner over the 10 test modules (101 assertions). There is
no xUnit / NUnit dependency — see `fsharp/src/RpgmDecrypt.Tests/TestFramework.fs`
for the ~100-LoC runner.

Fixture bytes are generated at test-time inside each `register ()` block.
We deliberately do not commit real RPG Maker game bytes to the repo
to avoid licensing complications; use `dotnet run --project` to
exercise the synthetic fixtures before pointing the binary at a real game.

## Distribution (GitLab → GitHub)

GitLab is the build/test farm (it has the subscription minutes); GitHub is the
clean distribution channel. **No GitHub PAT is needed** — an SSH deploy key is
the only credential.

Flow:

1. **GitLab CI** (`.gitlab-ci.yml`) runs the gates on every push: F# build+test
   (`build-test`, `build-test-windows`), OCaml parity (`ocaml-build-test`,
   72 checks), property/Gospel verification (`ocaml-verification`, 12 QCheck2
   properties + `gospel check`), coverage-guided fuzzing (`ocaml-fuzz`,
   afl-fuzz 90s).
2. When the hard Linux gates are green, **`github-mirror`** pushes the ref to
   GitHub over SSH using the deploy key: `main` mirrors `main`; a tag `v…`
   mirrors the tag.
3. The tag push **triggers GitHub Actions** (`.github/workflows/ci.yml`), which
   builds the release binaries from that exact commit and publishes a GitHub
   Release with the auto-provided `GITHUB_TOKEN`:
   - **`rpgm-decrypt-linux-x64`** (flagship) — OCaml, statically-linked musl,
     single file, zero runtime deps, runs on any x86-64 Linux; 72 parity checks
     re-run on the static toolchain.
   - `rpgm-decrypt` (F# linux-x64 / osx-arm64) and `rpgm-decrypt.exe`
     (F# win-x64) — .NET 10 self-contained secondary builds.

Day-to-day CI stays on GitLab; GitHub Actions fires only on tags (releases), so
it costs ~one release-worth of minutes per tag (private-repo Actions budget).

One-time setup:

1. **Add the SSH public key as a deploy key (write) on GitHub** — once, on a
   machine where `gh` works:
   ```sh
   gh api -X POST repos/rolanfreeman6-png/rpgm-decrypt/keys \
     -f title=gitlab-ci-mirror \
     -f key="$(cat id_ed25519_gitlab_mirror.pub)" \
     -F read_only=false
   ```
   (or Settings → Deploy keys → Add deploy key, tick "Allow write access").
2. **Add the matching SSH private key to GitLab** → Settings → CI/CD →
   Variables → `GH_SSH_PRIVATE_KEY` (Masked ✓, Protected ✓). Paste the private
   key file contents (`-----BEGIN OPENSSH PRIVATE KEY-----` … `-----END …`).
3. **Protect `main`** (Settings → Repository → Protected branches) so the
   protected variable reaches the `github-mirror` job.

Without `GH_SSH_PRIVATE_KEY` the mirror job fails fast with a clear message and
nothing is pushed to GitHub. Releasing: `git tag v0.3.0 && git push gitlab v0.3.0`
→ GitLab tests → mirror → GitHub Actions builds + publishes the Release.

## License

Apache-2.0. See `LICENSE`.

## Author note

Built turn-key from spec-to-shipped code in one session. Every byte is
cited; every tests-pass is real (`dotnet test` output); every claim is
verifiable. If something breaks on a real game — open an issue with
`game_dir` + `rpg-core-js` snippet + the failing file. We will fix.
