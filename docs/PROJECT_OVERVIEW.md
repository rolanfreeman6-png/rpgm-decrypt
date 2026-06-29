# rpgm-decrypt — Project Overview

> **Repository:** [github.com/rolanfreeman6-png/rpgm-decrypt](https://github.com/rolanfreeman6-png/rpgm-decrypt) (private)
> **Language:** F# / .NET 10
> **License:** Apache-2.0
> **Version:** 0.2.0
> **Tests:** 101/101 pass (Release, 0 warnings)

---

## Что это

CLI-утилита для извлечения зашифрованных ассетов из RPG Maker игр.
Поддерживает 5 поколений движка: **XP**, **VX**, **VX Ace**, **MV**, **MZ**.
Один self-contained бинарник, cross-platform, без зависимостей.

```text
$ rpgm-decrypt ./game ./decrypted
[key] System.json (...)
scanned=749  decrypted=391  failed=0
exit 0
```

---

## Где что лежит

### Документация

| Файл | Описание | GitHub |
|---|---|---|
| `README.md` | Публичное описание, usage, флаги CLI, exit-codes | [→](https://github.com/rolanfreeman6-png/rpgm-decrypt/blob/main/README.md) |
| `docs/THEORY.md` | Технический brief: magic-таблицы, алгоритмы, layouts | [→](https://github.com/rolanfreeman6-png/rpgm-decrypt/blob/main/docs/THEORY.md) |
| `CONTRIBUTING.md` | Clean-room правила, стиль PR, ссылки на спеки | [→](https://github.com/rolanfreeman6-png/rpgm-decrypt/blob/main/CONTRIBUTING.md) |
| `LICENSE` | Apache-2.0 (патент-grant) | [→](https://github.com/rolanfreeman6-png/rpgm-decrypt/blob/main/LICENSE) |

### CI / Infrastructure

| Файл | Описание | GitHub |
|---|---|---|
| `.github/workflows/ci.yml` | GitHub Actions: 3-OS matrix (ubuntu/windows/macos), build + test + publish self-contained binaries | [→](https://github.com/rolanfreeman6-png/rpgm-decrypt/blob/main/.github/workflows/ci.yml) |
| `.gitignore` | Исключения: bin/obj/artifacts, real-game fixtures | [→](https://github.com/rolanfreeman6-png/rpgm-decrypt/blob/main/.gitignore) |
| `fsharp/src/RpgmDecrypt.slnx` | .NET solution (новый XML-формат .slnx) | [→](https://github.com/rolanfreeman6-png/rpgm-decrypt/blob/main/fsharp/src/RpgmDecrypt.slnx) |

### Core Library (`fsharp/src/RpgmDecrypt.Core/`)

Чистая функциональная библиотека алгоритмов — без I/O-side-effects кроме
явно помеченных функций.

| Файл | LoC | Назначение | GitHub |
|---|---:|---|---|
| `Types.fs` | ~90 | `Format` DU (XP/VX/VxAce/MV/MZ), `Outcome`, `RunSummary` | [→](https://github.com/rolanfreeman6-png/rpgm-decrypt/blob/main/fsharp/src/RpgmDecrypt.Core/Types.fs) |
| `Crypto.fs` | ~120 | XOR-примитивы, magic-byte константы, hex-decode, `looksLikePlaintext` | [→](https://github.com/rolanfreeman6-png/rpgm-decrypt/blob/main/fsharp/src/RpgmDecrypt.Core/Crypto.fs) |
| `VxAceKey.fs` | ~80 | RGSS3 key derivation (`seed*9+3`), filename XOR, payload rotating XOR (`key*7+3`) | [→](https://github.com/rolanfreeman6-png/rpgm-decrypt/blob/main/fsharp/src/RpgmDecrypt.Core/VxAceKey.fs) |
| `KeyDiscovery.fs` | ~130 | Auto-find ключа: `www/js/System.json` → `www/data/System.json` → `rpg_core.js` → `*.js` sweep. Wordlist validation. | [→](https://github.com/rolanfreeman6-png/rpgm-decrypt/blob/main/fsharp/src/RpgmDecrypt.Core/KeyDiscovery.fs) |
| `Format.Mv.fs` | ~80 | MV/MZ XOR-decrypt + plaintext detection (PNG/OGG/M4A/WebP/JPG) | [→](https://github.com/rolanfreeman6-png/rpgm-decrypt/blob/main/fsharp/src/RpgmDecrypt.Core/Format.Mv.fs) |
| `Format.Mz.fs` | ~60 | MZ `.pak` = ZIP + per-entry MV XOR | [→](https://github.com/rolanfreeman6-png/rpgm-decrypt/blob/main/fsharp/src/RpgmDecrypt.Core/Format.Mz.fs) |
| `RgssadCore.fs` | ~110 | Shared XP+VX `.rgssad` parser: header check, entry-table loop (sentinel DU), bounds/negative-nameLen guard, filename XOR, readEntry | [→](https://github.com/rolanfreeman6-png/rpgm-decrypt/blob/main/fsharp/src/RpgmDecrypt.Core/RgssadCore.fs) |
| `Format.Xp.fs` | ~45 | XP `.rgssad` v1: thin wrapper over `RgssadCore` (version `0x01`, `name_len=0` sentinel) | [→](https://github.com/rolanfreeman6-png/rpgm-decrypt/blob/main/fsharp/src/RpgmDecrypt.Core/Format.Xp.fs) |
| `Format.Vx.fs` | ~42 | VX `.rgssad` v2: thin wrapper over `RgssadCore` (version `0x02`, `size=0 && name_len=0` sentinel) | [→](https://github.com/rolanfreeman6-png/rpgm-decrypt/blob/main/fsharp/src/RpgmDecrypt.Core/Format.Vx.fs) |
| `Format.VxAce.fs` | ~150 | VXAce `.rgss3a` v3: master-seed → masterKey → offset/size/key/nameLen/names + payload decrypt | [→](https://github.com/rolanfreeman6-png/rpgm-decrypt/blob/main/fsharp/src/RpgmDecrypt.Core/Format.VxAce.fs) |
| `Format.fs` | ~100 | Top-level dispatcher: classify by extension + magic bytes → Format | [→](https://github.com/rolanfreeman6-png/rpgm-decrypt/blob/main/fsharp/src/RpgmDecrypt.Core/Format.fs) |
| `Walk.fs` | ~55 | Recursive directory walker, extension filter | [→](https://github.com/rolanfreeman6-png/rpgm-decrypt/blob/main/fsharp/src/RpgmDecrypt.Core/Walk.fs) |
| `Log.fs` | ~95 | NDJSON + human-readable log sinks (stderr) | [→](https://github.com/rolanfreeman6-png/rpgm-decrypt/blob/main/fsharp/src/RpgmDecrypt.Core/Log.fs) |
| `Report.fs` | ~190 | Orchestrator: walk → classify → decrypt → write mirror-tree → RunSummary | [→](https://github.com/rolanfreeman6-png/rpgm-decrypt/blob/main/fsharp/src/RpgmDecrypt.Core/Report.fs) |

### CLI (`fsharp/src/RpgmDecrypt.Cli/`)

| Файл | LoC | Назначение | GitHub |
|---|---:|---|---|
| `the CLI module` | ~180 | Arg parser, key resolution (--password/--password-file/--vxace-seed/auto), exit codes | [→](https://github.com/rolanfreeman6-png/rpgm-decrypt/blob/main/fsharp/src/RpgmDecrypt.Cli/the CLI module) |

### Tests (`fsharp/src/RpgmDecrypt.Tests/`)

In-process test runner (без xUnit/NUnit зависимостей).

| Файл | Tests | Что проверяет | GitHub |
|---|---:|---|---|
| `TestFramework.fs` | — | ~100 LoC runner: register/snapshot/runAll/assertEqual/assertByteEqual | [→](https://github.com/rolanfreeman6-png/rpgm-decrypt/blob/main/fsharp/src/RpgmDecrypt.Tests/TestFramework.fs) |
| `Generator.fs` | — | Synthetic-but-realistic MV game fixture builder + MZ .pak + XP .rgssad | [→](https://github.com/rolanfreeman6-png/rpgm-decrypt/blob/main/fsharp/src/RpgmDecrypt.Tests/Generator.fs) |
| `TypesTests.fs` | 3 | Format DU mapping, RunSummary.tally | [→](https://github.com/rolanfreeman6-png/rpgm-decrypt/blob/main/fsharp/src/RpgmDecrypt.Tests/TypesTests.fs) |
| `CryptoTests.fs` | 9 | hex-decode, XOR inverse, zero-key identity, magic detection, invalid-input rejection | [→](https://github.com/rolanfreeman6-png/rpgm-decrypt/blob/main/fsharp/src/RpgmDecrypt.Tests/CryptoTests.fs) |
| `KeyDiscoveryTests.fs` | 3 | System.json key find, wordlist validation, empty wordlist rejection | [→](https://github.com/rolanfreeman6-png/rpgm-decrypt/blob/main/fsharp/src/RpgmDecrypt.Tests/KeyDiscoveryTests.fs) |
| `FormatMvTests.fs` | 3 | Plaintext PNG, XOR-encrypted PNG, wrong-key Unsure | [→](https://github.com/rolanfreeman6-png/rpgm-decrypt/blob/main/fsharp/src/RpgmDecrypt.Tests/FormatMvTests.fs) |
| `FormatMzTests.fs` | 2 | Non-ZIP rejection, synthetic Pak decrypt | [→](https://github.com/rolanfreeman6-png/rpgm-decrypt/blob/main/fsharp/src/RpgmDecrypt.Tests/FormatMzTests.fs) |
| `FormatXpTests.fs` | 3 | Real-layout parse, bad magic, bad version | [→](https://github.com/rolanfreeman6-png/rpgm-decrypt/blob/main/fsharp/src/RpgmDecrypt.Tests/FormatXpTests.fs) |
| `FormatVxTests.fs` | 4 | v2 round-trip, bad magic, bad version, negative-nameLen guard | [→](https://github.com/rolanfreeman6-png/rpgm-decrypt/blob/main/fsharp/src/RpgmDecrypt.Tests/FormatVxTests.fs) |
| `FormatVxAceTests.fs` | 5 | End-to-end encrypt+parse+decrypt, master-key formula, negative-nameLen regression, bad magic, bad version | [→](https://github.com/rolanfreeman6-png/rpgm-decrypt/blob/main/fsharp/src/RpgmDecrypt.Tests/FormatVxAceTests.fs) |
| `EndToEndTests.fs` | 4 | MV .png_ round-trip; safeJoin unit; MZ Zip-Slip blocked; MZ nested-path preserved | [→](https://github.com/rolanfreeman6-png/rpgm-decrypt/blob/main/fsharp/src/RpgmDecrypt.Tests/EndToEndTests.fs) |
| `EndToEndRealFixtureTests.fs` | 5 | Full MV pipeline, MZ .pak, XP .rgssad, plaintext pass-through, dry-run | [→](https://github.com/rolanfreeman6-png/rpgm-decrypt/blob/main/fsharp/src/RpgmDecrypt.Tests/EndToEndRealFixtureTests.fs) |
| `Main.fs` | — | EntryPoint: registers all test modules, runs TestFramework.runAll | [→](https://github.com/rolanfreeman6-png/rpgm-decrypt/blob/main/fsharp/src/RpgmDecrypt.Tests/Main.fs) |

---

## Engine support matrix

| Engine | Extension | Encryption | Status | Real-tested? |
|---|---|---|---|---|
| **MV** | `.png_` `.ogg_` `.m4a_` `.rpgmvp/o/m` | XOR with `encryptionKey` from System.json (16 bytes, cyclic) | ✅ Full decrypt + pass-through | ✅ Synthetic + WYDTTM-Windows (1370 files, 497 MB) |
| **MZ** | `.pak` | ZIP + per-entry MV XOR | ✅ Full decrypt | ✅ Synthetic |
| **VX Ace** | `.rgss3a` | Master-seed `*9+3` → XOR header fields; payload rotating `*7+3` | ✅ Full decrypt + payload | ✅ **Hello Charlotte EP1** (39 MB, 391 entries, 223 MB output) |
| **XP** | `.rgssad` | Filename XOR with magic prefix | ✅ Structural walker (TOC) | ✅ Synthetic |
| **VX** | `.rgss2a` / `.rgssad` v2 | Same as XP | ✅ Structural walker (TOC) | ✅ Synthetic |

---

## CLI usage

```text
rpgm-decrypt [OPTIONS] <game_dir> [<out_dir>]
```

| Flag | Default | Description |
|---|---|---|
| `--password <hex32>` | — | MV/MZ 32-char hex key |
| `--password-file <path>` | — | Newline-separated candidate keys (tries each against cipher sample) |
| `--vxace-seed <8hex>` | — | VX Ace master-seed (bypasses title-derivation) |
| `--log-format human\|json` | `human` | stderr log format |
| `--report-format human\|json` | `human` | stdout final report |
| `--dry-run` | off | Walk + classify, write nothing |
| `--quiet` | off | Suppress per-file progress |
| `--version` | — | Print version |
| `-h, --help` | — | Print help |

### Exit codes

| Code | Meaning |
|---|---|
| 0 | Success |
| 1 | Internal error |
| 2 | Usage error |
| 3 | I/O error |
| 4 | No encryption key found |
| 5 | Partial: some decrypted, some failed |

---

## Build

```bash
dotnet build -c Release
dotnet run --project fsharp/src/RpgmDecrypt.Tests -c Release     # 101 assertions
dotnet publish fsharp/src/RpgmDecrypt.Cli -c Release -r win-x64 \
    --self-contained true -p:PublishSingleFile=true \
    -p:IncludeNativeLibrariesForSelfExtract=true          # single .exe
```

---

## CI

GitHub Actions workflow: `.github/workflows/ci.yml`

- **Matrix:** ubuntu-latest / windows-latest / macos-latest × x64
- **Steps:** restore → build (`TreatWarningsAsErrors=true`) → run 101 assertions
- **Publish:** linux-x64 / osx-arm64 / win-x64 self-contained single-file binaries (uploaded as artifacts; SHA-pinned actions)
- **Release:** on tag `v*`, binaries auto-attached to GitHub Release

Live status: [github.com/rolanfreeman6-png/rpgm-decrypt/actions](https://github.com/rolanfreeman6-png/rpgm-decrypt/actions)

---

## Git history

```
63c11f8  Real VX Ace payload decryption + CLI --vxace-seed flag
ec286f1  Format.VxAce: defensive guard against negative name_len
1ee71a4  KeyDiscovery: probe multiple System.json/rpg_core.js paths
a51455d  Fix pass-through plaintext file path + classifier
f16cc34  End-to-end synthetic fixtures + CI matrix
18c292b  Audit-driven fixes (CRITICAL/HIGH/MEDIUM)
dba2644  Initial commit: rpgm-decrypt v0.1.0
```

---

## Real-world tests conducted

| Game | Engine | Size | Result |
|---|---|---|---|
| **Hello Charlotte EP1** (`F:\fr\g\HC_EP1`) | VX Ace | 39 MB `.rgss3a` | ✅ 391 entries decrypted, 223 MB output, OGG/PNG magic verified |
| **WYDTTM-Windows** (`F:\WYDTTM-Windows`) | MV | 1370 files, 497 MB | ✅ Pass-through (encryption off), no crash, exit=4 (no key) |
| **volume-puzzle** (GitHub) | MV | 186 files, 33 MB | ✅ Pass-through (encryption off), exit=4 |
| **GitHooksSample** (GitHub) | MZ | 410 files | ✅ Pass-through (encryption off), exit=4 |

---

## Bugs found and fixed via real-game testing

| Bug | Source | Fix commit |
|---|---|---|
| `Format.Xp.fs` wrong byte order (`name_len,name,size,offset` instead of `size,offset,name_len,name`) | Audit | `18c292b` |
| `Crypto.magicRgssadPrefix` F# `\0` escape → 8 bytes instead of 7 | Audit | `18c292b` |
| `KeyDiscovery.discoverWithWordlist` ignored wordlist (no-op) | Audit | `18c292b` |
| `Dispatch.classify` dropped `.png/.ogg/.m4a` plaintext (pass-through broken) | WYDTTM test | `a51455d` |
| `copyThrough` missing mkdir before `File.Copy` | Synthetic fixture | `a51455d` |
| `KeyDiscovery` only checked `www/js/`, not `www/data/` (deployed layout) | WYDTTM test | `1ee71a4` |
| `Format.VxAce.parse` crash on negative `name_len` (`Array.zeroCreate(-N)`) | Hello Charlotte EP1 | `ec286f1` |
| `Format.VxAce.parse` wrong entry layout (missing `entry_key` field) | uuksu reference study | `63c11f8` |

A full static + build audit (`AUDIT_2026-06-28.md`) found and fixed: the
`the CLI module` DU-case typo that broke the warnings-as-errors build and
mislabelled MV/MZ reports (C-1); Zip-Slip arbitrary-write in MZ/VX Ace
extraction (C-2); a missing negative-`name_len` guard in `Format.Vx` (I-1);
MZ entries all collapsing to one output path (I-5); plus exit-code, CI
release-upload, double-decrypt, and documentation fixes.
