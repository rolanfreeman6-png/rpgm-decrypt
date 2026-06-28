# rpgm-decrypt — OCaml port

A faithful OCaml port of the F# `RpgmDecrypt` core + CLI. The F# sources under
`../src/` are kept as-is "for posterity"; this is an independent OCaml
implementation of the same algorithms.

> The original project plan was OCaml (see `../README.md` §"F# (and not OCaml)").
> This directory realises that plan: OCaml 5.x + dune, no .NET.

## What changed vs the F# version

The logic is ported 1:1; only the host-platform plumbing differs, because OCaml
has no .NET BCL:

| F# / .NET | OCaml |
|---|---|
| `byte[]` | `bytes` |
| discriminated unions / records | variants / records |
| `Result<'T,'E>` / `Option` | `('a,'e) result` / `option` |
| `System.IO.Compression.ZipArchive` | **camlzip** (`Zip`) |
| `System.Text.Json` | **yojson** |
| `System.Text.RegularExpressions` | **re** (`Re.Pcre`) |
| `System.IO.File` / `DateTime` | stdlib `In_channel`/`Out_channel`, `unix` |
| `uint32` wraparound | `int` masked with `land 0xFFFFFFFF` |

All audit fixes carried over: Zip-Slip containment (`Report.safe_join`), the
shared XP/VX parser (`Rgssad_core`), the VX-Ace negative-`name_len` guard, the
MZ `rename_by_kind` argument order, single-decrypt MV path, and the `4=no-key`
exit-code semantics. Note: F# read each archive length field as `uint32` then
cast to `int32` (a high-bit value went negative and was caught by `< 0`); OCaml's
63-bit `int` keeps it a large positive, caught by the `pos + len > buf_len`
bounds check instead — same result, no negative-wrap.

## Layout

```
ocaml/
  dune-project
  lib/     io types crypto rgssad_core xp vx vxace_key vxace mv mz
           dispatch walk log key_discovery report   (= RpgmDecrypt.Core)
  bin/     main.ml                                   (= Program.fs, CLI)
  test/    test.ml                                   (in-process parity tests)
```

## Build / test / run

Requires OCaml 5.x + dune + camlzip, yojson, re. On Debian/Ubuntu:

```sh
sudo apt-get install -y ocaml ocaml-dune ocaml-findlib \
    libzip-ocaml-dev libyojson-ocaml-dev libre-ocaml-dev
```

```sh
dune build  --profile release            # compile (0 warnings)
dune exec --profile release test/test.exe   # 44 parity checks
dune exec --profile release bin/main.exe -- --help
dune exec --profile release bin/main.exe -- <game_dir> <out_dir> [--password <hex32> | --vxace-seed <8hex>]
```

## Verification

- `test.exe`: 44/44 checks pass (crypto, MV, XP/VX, VX Ace, MZ via camlzip,
  end-to-end `Report.run`, `safe_join`, MZ Zip-Slip block).
- CLI parity: byte-identical JSON report to the F# binary on a synthetic MV
  game (`"per_format":{"MV":1}`, exit 0; decrypted PNG has the `89 50 4E 47`
  signature).
- Real games: VX Ace `Game.rgss3a` archives decrypted (391 + 250 entries, 0
  failures; extracted PNGs carry valid signatures); an MV game with encryption
  off correctly reports `exit 4` (no key) — matching the F# behaviour.
