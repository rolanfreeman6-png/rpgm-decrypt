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
  dune-project          (lang dune 3.0; release env: warnings-as-errors)
  lib/     io types crypto rgssad_core xp vx vxace_key vxace mv mz
           dispatch walk log key_discovery report   (= RpgmDecrypt.Core)
           + a narrow .mli per module (Gospel specs in crypto/vxace_key/
             rgssad_core/dispatch/report .mli)
  bin/     main.ml                                   (= the CLI module, CLI)
  test/    test.ml      (72 in-process parity checks)
           prop/prop.ml (12 QCheck2 property tests)
  fuzz/    fuzz.ml      (AFL-instrumented fuzz target)
```

## Build / test / run

Requires OCaml 5.x + dune + camlzip, yojson, re. The property tests need
`qcheck`; the Gospel spec type-check needs `gospel` (Gospel 0.3.1 requires
OCaml ≤ 5.3, so keep a separate switch for it — see "Formal verification").

```sh
# base toolchain (Debian/Ubuntu) — builds the library, CLI, and parity tests:
sudo apt-get install -y ocaml ocaml-dune ocaml-findlib \
    libzip-ocaml-dev libyojson-ocaml-dev libre-ocaml-dev

# property tests + Gospel specs (opam; qcheck & gospel are not in the apt set):
opam install qcheck gospel
```

```sh
dune build --profile release               # 0 warnings (strict flags + warn-error)
dune exec --profile release test/test.exe  # 72 parity checks
dune exec --profile release test/prop/prop.exe  # 12 QCheck2 properties (seed 42)
dune exec --profile release bin/main.exe -- --help
dune exec --profile release bin/main.exe -- <game_dir> <out_dir> \
    [--password <hex32> | --vxace-seed <8hex>]
```

A lockfile of the exact dependency versions is committed as
`rpgm-decrypt.opam.locked` (direct deps only, portable). The dependency
manifest is `rpgm-decrypt.opam`.

## Formal verification & guarantees

Behavioural parity with the F# original is the source of truth and is enforced
by the 72 in-process parity tests; the layers below add static and formal
guarantees on top of that. Each layer is honestly classified by what it
actually verifies.

| Layer | Status | What it guarantees |
|---|---|---|
| Narrow `.mli` interfaces | done, verified | Every `lib/` module has a documented public interface; internal helpers are hidden (see commit history). |
| Strict compiler flags | done, verified | `-w +a-4-40-42-44-45-70 -strict-sequence -strict-formats -principal`, warnings-as-errors in the `release` profile. Build is warning-free (verified via `dune build --verbose`: every command carries `-warn-error +a-…`). |
| Parity tests | done, verified | 72/72 checks pass (crypto, MV, XP/VX, VX Ace, MZ, end-to-end `Report.run`, `safe_join`, Zip-Slip block, `read_u32_le` high bytes, per-kind extension map). |
| QCheck properties | done, verified | 12/12 properties pass (seed 42): XOR involution + length, hex-key round-trip, `derive_master_key = u32(seed*9+3)` over 2³², `decode_payload` involution, parser/`Mv.decrypt`/`Vxace_key` totality (never throw on arbitrary bytes), `safe_join` containment (Zip-Slip), `choose_output_extension` totality. |
| Mutation testing | done, verified | 7 directed mutants, 7/7 killed after two coverage-gap fixes (see `MUTATION_REPORT.md`). |
| Gospel specs | done, type-check-verified locally; clean exit-0 on Linux CI | Specs on the pure core (see below). Gospel 0.3.1 on Windows/mingw crashes with `output_value: not a binary channel` *after* successful type-checking (a text-mode marshal bug); type errors are reported *before* the crash, so a spec is taken as valid when `gospel check`'s only failure is that crash (sanity-checked with a deliberately erroneous spec). The `ocaml-verification` CI job gives a clean exit 0 on Linux. |
| ortac RAC | not run (tool not applicable) | `ortac qcheck-stm` (ortac 0.8.0) targets *stateful* APIs (needs a `sut`/`init_sut` model); the rpgm-decrypt core is stateless, so it does not apply. The `ortac wrapper` RAC command does not exist in 0.8.0. Runtime contract checking of the Gospel `ensures` is instead provided by the QCheck property suite, which evaluates the same contracts at runtime with 0 violations (e.g. `p_derive_master_key` ↔ `derive_master_key` ensures, `p_safe_join_*` ↔ `safe_join` containment). |
| Cameleer/Why3 proofs | not run locally; Linux CI job provided (manual) | `ocaml-cameleer` CI job installs cameleer + why3 + alt-ergo and runs the prover on the proof targets (`Vxace_key.derive_master_key`, `Report.safe_join`, `Rgssad_core`). Not run on this Windows machine (no local Linux/Why3 toolchain). |

### Gospel specs — what is specified

Gospel 0.3.1 ships **no `Bytes`/`String`/`Char` theory**, so specifications are
split:

- **Fully grounded** in Gospel's integer/bitwise theory (these are the strong,
  exact contracts):
  - `Vxace_key.u32`: `r = logand x 4294967295`
  - `Vxace_key.decode_u32`: `r = logxor cipher key`
  - `Vxace_key.key_byte`: `requires 0 <= j <= 3; r = logand (shift_right key (8*j)) 255`
  - `Dispatch.choose_output_extension`: the total `kind`/`input_ext → extension`
    match (exact).
- **Axiomatised** (bytes/string/char operations are uninterpreted logic
  functions, because Gospel 0.3.1 has no theory for them). These document the
  contract and are checked at runtime by the QCheck properties / parity tests;
  a Cameleer proof of them is conditional on the axiomatised helpers:
  - `Crypto.xor_transform` (length + per-byte XOR formula), `sub_array_eq`,
    `starts_with`, `hex_nibble` (+ `raises Invalid_argument`), `decode_hex_key`
    (length 16), `is_*_magic` (length lower bound).
  - `Rgssad_core.read_u32_le` (LE formula), `xor_decode_name`, `parse`
    (total — no `raises` clause; `end_pos` within buffer), `read_entry` (clamped).
  - `Vxace_key.derive_master_key` (`u32 (seed*9+3)`), `decode_filename`,
    `decode_payload` (length).
  - `Report.safe_join` (Zip-Slip containment: any `Some` result is the
    normalised root or a descendant of it).

I/O modules (`io`, `walk`, `mz`, `report.run`, `log`, `key_discovery`) are not
given deductive specs — they are covered by the parity tests and the
`classify`/`dispatch` behaviour, as the mission specifies.

### Reproducing the verification locally (Windows)

The product builds on the native Windows switch (OCaml 5.5.0). Gospel 0.3.1
needs OCaml ≤ 5.3, so create an isolated switch for it (this does **not** touch
the 5.5.0 switch):

```sh
opam switch create rpgm-verify ocaml-base-compiler.5.3.0 --no-switch
opam install --switch=rpgm-verify dune camlzip yojson re qcheck gospel
# build the lib (produces the .cmi needed for cross-module gospel check):
opam exec --switch=rpgm-verify -- dune build lib/rpgm.cma
# compile the two cross-module .cmi dependencies, then check each spec'd .mli:
opam exec --switch=rpgm-verify -- ocamlc -c -I . lib/types.mli   # -> Types.cmi
opam exec --switch=rpgm-verify -- ocamlc -c -I . lib/log.mli     # -> Log.cmi
opam exec --switch=rpgm-verify -- gospel check lib/crypto.mli
opam exec --switch=rpgm-verify -- gospel check lib/vxace_key.mli
opam exec --switch=rpgm-verify -- gospel check lib/rgssad_core.mli
opam exec --switch=rpgm-verify -- gospel check lib/dispatch.mli -L .
opam exec --switch=rpgm-verify -- gospel check lib/report.mli -L .
```

On Windows each `gospel check` exits 125 with the `output_value` marshal crash
*after* successful type-checking; on Linux (CI) it exits 0.
