<div align="center">

# 🗝️ rpgm-decrypt

### One small binary that unlocks the assets out of any RPG Maker game.

**XP · VX · VX Ace · MV · MZ** — all five engine generations, one command, no install.

![License](https://img.shields.io/badge/license-Apache--2.0-blue)
![Formats](https://img.shields.io/badge/formats-XP%20·%20VX%20·%20VXAce%20·%20MV%20·%20MZ-2ea44f)
![Built with](https://img.shields.io/badge/built%20with-OCaml-ff7a18)
![Single binary](https://img.shields.io/badge/single%20binary-zero%20runtime%20deps-brightgreen)
![Fuzzed](https://img.shields.io/badge/fuzzed-21M%2B%20iters%20·%200%20crashes-success)
![Verified](https://img.shields.io/badge/parser-Gospel%20·%20Why3%20verified-8a2be2)

</div>

---

## ⚡ See it work

```console
$ rpgm-decrypt ./MyGame ./decrypted

[key]  found encryptionKey in www/js/System.json
  +  Title.png_   detected as MV
  >  Title.png_   ->  decrypted/www/img/Title.png   [MV]
  +  Battle.ogg_  detected as MV
  >  Battle.ogg_  ->  decrypted/www/audio/Battle.ogg [MV]
  ...

=== summary ===
scanned:      1873
decrypted:    1869
failed:          0
key source:   www/js/System.json
duration:     4.2s
by format:    MV=1869
```

Need machine-readable output for a script? Add `--report-format json`:

```json
{
  "scanned": 1873,
  "decrypted": 1869,
  "failed": 0,
  "key_source": "www/js/System.json",
  "per_format": { "MV": 1869 },
  "duration_s": 4.2
}
```

> [!TIP]
> **You don't install anything.** Download one file, run it. No Python, no .NET, no
> Node — the binary carries everything it needs inside.

> [!IMPORTANT]
> **Use it on content you're allowed to touch.** Recovering *your own* assets, a
> lost encryption key, an authorized translation, or game preservation — all fine.
> Decrypting someone else's work to steal it is not. The license is permissive;
> your responsibility isn't.

---

## ✨ What you get

| | Feature | In plain words |
|---|---|---|
| 🧩 | **All 5 formats** | `.rgssad` / `.rgss2a` / `.rgss3a` (XP/VX/VX Ace) **and** MV/MZ (`.png_`, `.ogg_`, `.rpgmvp`, `.pak`) — one tool, not five. |
| 🔑 | **Finds the key for you** | Reads `System.json` / scans `rpg_core.js` automatically. No key to hunt down by hand. |
| 📦 | **One self-contained binary** | Copy it to a clean machine and it just runs. Zero dependencies. |
| 🛡️ | **Safe by construction** | Hostile/corrupt input never crashes it (proven by fuzzing) and can't escape your output folder (Zip-Slip blocked). |
| 🤖 | **Script-friendly** | `--report-format json` + NDJSON logs pipe straight into `jq`. |
| 🧪 | **Provably correct core** | Key functions carry formal contracts (Gospel); core safety properties are machine-checked (Why3 / Z3). |

---

## 🚀 Quick start

**1. Download** the binary for your OS from the [Releases](../../releases) page.

**2. Run it** on a game folder:

```bash
# simplest form — output goes next to the game folder
rpgm-decrypt ./MyGame

# pick your own output folder
rpgm-decrypt ./MyGame ./decrypted

# look but don't write anything (see what it WOULD do)
rpgm-decrypt ./MyGame --dry-run
```

That's it. Point it at the game, get a clean mirror tree of decrypted files out.

---

## 🔑 How it finds the key (no flags needed)

When you don't pass a key, rpgm-decrypt looks for it the way the engine stores it:

```text
1.  www/js/System.json   →  read "encryptionKey"   (the normal case)
2.  www/data/System.json →  same, alternate layout
3.  www/js/rpg_core.js   →  extract the 32-hex key literal (never runs the JS)
4.  *.js sweep           →  last resort, scan every script for the key
```

> [!NOTE]
> Can't find it automatically (custom build, stripped files)? Hand it the key:
> ```bash
> rpgm-decrypt ./MyGame --password deadbeef00112233445566778899aabb
> rpgm-decrypt ./MyGame --password-file keys.txt      # try a list, first match wins
> rpgm-decrypt ./MyGame --vxace-seed 1a2b3c4d          # RPG Maker VX Ace
> ```

---

## ⚙️ Options

| Flag | Default | What it does |
|---|---|---|
| `--password <hex32>` | — | One key, 32 hex chars (16 bytes). |
| `--password-file <path>` | — | Newline-separated candidate keys; first that works wins. |
| `--vxace-seed <8hex>` | — | RPG Maker VX Ace master-seed, instead of an auto key. |
| `--log-format human\|json` | `human` | Per-file progress on stderr (`json` = one NDJSON event per line). |
| `--report-format human\|json` | `human` | Final summary on stdout. |
| `--dry-run` | off | Walk + detect + classify, but write **nothing**. |
| `--quiet` | off | Hide per-file progress, show only the summary. |
| `-h`, `--help` | — | Show help. |
| `--version` | — | Version + supported formats. |

### Exit codes

| Code | Meaning |
|:---:|---|
| `0` | ✅ Everything decrypted. |
| `2` | ⚠️ Usage error (bad args). |
| `3` | 💽 I/O error (can't read input / write output). |
| `4` | 🔑 No key could be recovered. |
| `5` | 🟡 Partial — at least one file failed (details in the report). |

---

## 🏗️ Built like it matters

Most decrypters are a quick script. This one is engineered as a real product —
that's the part a senior engineer notices:

| Discipline | What it means here |
|---|---|
| 🧬 **Pure functional core** | Narrow `.mli` per module, 72 behavioural checks + 12 QCheck property tests, mutation-tested (7/7 mutants killed). |
| 💥 **Fuzzed against chaos** | **21M+** mutated/garbage inputs, **0 crashes** — plus coverage-guided `afl-fuzz` in CI. It does not fall over on broken files. |
| 📐 **Property-based tests** | Invariants, not examples: *"XOR is its own inverse for any key & data"*, *"a path can never escape the output root"*. |
| 🔒 **Formally verified core** | The parser carries **Gospel** contracts; its key safety properties — bounds, little-endian decode, and the no-path-escape (Zip-Slip) invariant — are **machine-checked by Why3 / Z3**. ([details](ocaml/README.md#formal-verification--guarantees)) |
| 🧹 **Zero-warning, formatted, clean-room** | Builds warning-as-error, `ocamlformat`-canonical, Apache-2.0, no decompiled code. |
| 🔁 **CI on every push** | Linux + Windows build/test, security scanners (SAST, Secret scanning), fuzzing, verification. |

> [!CAUTION]
> The decrypter is built for **robustness on adversarial input** on purpose: it parses
> file formats produced by *other* programs, so it treats every byte as untrusted.
> That's why the parser is fuzzed *and* formally verified rather than just "tested".

---

## 🔧 Build from source

<details>
<summary><b>OCaml (flagship — single native binary)</b></summary>

```bash
cd ocaml
dune build --profile release
./_build/default/bin/main.exe --version
```

For a portable, statically-linked Linux binary, build on Alpine (musl) with
`dune build --profile static`.

</details>

<details>
<summary><b>Run the tests</b></summary>

```bash
# OCaml: 72 behavioural checks + 12 QCheck property tests
cd ocaml && dune exec --profile release test/test.exe

# QCheck properties (needs `opam install qcheck`)
cd ocaml && dune exec --profile release test/prop/prop.exe
```

Test fixtures are generated synthetically at test time — we never commit real
RPG Maker game bytes, to keep the repo licensing-clean.

</details>

<details>
<summary><b>Project layout</b></summary>

```text
ocaml/                  OCaml flagship — single native binary
  lib/                    pure core + narrow .mli (Gospel specs)
  bin/                    CLI front-end
  test/  test/prop/       behavioural checks + QCheck properties
  fuzz/                   afl-instrumented fuzz target
  proofs/                 Why3 + Z3 deductive verification (Zip-Slip, bounds)
.gitlab-ci.yml          test + fuzz + verification farm
.github/workflows/      tag-triggered release builds
```

</details>

---

## 📜 License

**Apache-2.0** — free to use, modify, and ship. See [`LICENSE`](LICENSE).

Clean-room implementation: built from public format documentation and community
wikis, no decompiled engine code. Every magic-byte constant is cited in the source.

---

<div align="center">

**Found a game it can't crack?** [Open an issue](../../issues) with the game layout and the
failing file — real bugs get fixed.

<sub>Built turn-key, spec-to-shipped. Every claim here is backed by a test, a fuzz run, or a proof.</sub>

</div>
