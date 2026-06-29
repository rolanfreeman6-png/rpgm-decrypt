# rpgm-decrypt — OCaml

The OCaml implementation of the RPG Maker asset decryptor: a single native
binary (statically-linked musl on Linux — zero runtime deps) that unlocks XP,
VX, VX Ace, MV, and MZ archives. OCaml 5.x + dune.

## Platform mapping

The core is pure functional OCaml; host-platform plumbing uses these libraries
(OCaml has no .NET BCL):

| Concern | OCaml |
|---|---|
| byte buffers | `bytes` |
| sum types / records | variants / records |
| errors / absence | `('a,'e) result` / `option` |
| ZIP (`.pak`) | **camlzip** (`Zip`) |
| JSON (`System.json`) | **yojson** |
| regex (`rpg_core.js` scan) | **re** (`Re.Pcre`) |
| files / time | stdlib `In_channel`/`Out_channel`, `unix` |
| `uint32` wraparound | `int` masked with `land 0xFFFFFFFF` |

Safety features: Zip-Slip containment (`Report.safe_join`), the shared XP/VX
parser (`Rgssad_core`), the VX-Ace negative-`name_len` guard, the MZ
`rename_by_kind` argument order, single-decrypt MV path, and the `4=no-key`
exit-code semantics. Archive length fields are read as little-endian 32-bit
words into OCaml's 63-bit `int`; a corrupt high-bit length stays a large
positive and is caught by the `pos + len > buf_len` bounds check (Truncated),
never causing an out-of-bounds access.

## Layout

```
ocaml/
  dune-project          (lang dune 3.0; release env: warnings-as-errors)
  lib/     io types crypto rgssad_core xp vx vxace_key vxace mv mz
           dispatch walk log key_discovery report
           + a narrow .mli per module (Gospel specs in crypto/vxace_key/
             rgssad_core/dispatch/report .mli)
  bin/     main.ml                                   (= the CLI module, CLI)
  test/    test.ml      (72 in-process behavioural checks)
           prop/prop.ml (12 QCheck2 property tests)
  fuzz/    fuzz.ml      (AFL-instrumented fuzz target)
```

## Build / test / run

Requires OCaml 5.x + dune + camlzip, yojson, re. The property tests need
`qcheck`; the Gospel spec type-check needs `gospel` (Gospel 0.3.1 requires
OCaml ≤ 5.3, so keep a separate switch for it — see "Formal verification").

```sh
# base toolchain (Debian/Ubuntu) — builds the library, CLI, and behavioural tests:
sudo apt-get install -y ocaml ocaml-dune ocaml-findlib \
    libzip-ocaml-dev libyojson-ocaml-dev libre-ocaml-dev

# property tests + Gospel specs (opam; qcheck & gospel are not in the apt set):
opam install qcheck gospel
```

```sh
dune build --profile release               # 0 warnings (strict flags + warn-error)
dune exec --profile release test/test.exe  # 72 behavioural checks
dune exec --profile release test/prop/prop.exe  # 12 QCheck2 properties (seed 42)
dune exec --profile release bin/main.exe -- --help
dune exec --profile release bin/main.exe -- <game_dir> <out_dir> \
    [--password <hex32> | --vxace-seed <8hex>]
```

A lockfile of the exact dependency versions is committed as
`rpgm-decrypt.opam.locked` (direct deps only, portable). The dependency
manifest is `rpgm-decrypt.opam`.

## Formal verification & guarantees

The 72 in-process behavioural checks are the source of truth, enforced on every
push; the layers below add static and formal
guarantees on top of that. Each layer is honestly classified by what it
actually verifies.

| Layer | Status | What it guarantees |
|---|---|---|
| Narrow `.mli` interfaces | done, verified | Every `lib/` module has a documented public interface; internal helpers are hidden (see commit history). |
| Strict compiler flags | done, verified | `-w +a-4-40-42-44-45-70 -strict-sequence -strict-formats -principal`, warnings-as-errors in the `release` profile. Build is warning-free (verified via `dune build --verbose`: every command carries `-warn-error +a-…`). |
| Behavioural tests | done, verified | 72/72 checks pass (crypto, MV, XP/VX, VX Ace, MZ, end-to-end `Report.run`, `safe_join`, Zip-Slip block, `read_u32_le` high bytes, per-kind extension map). |
| QCheck properties | done, verified | 12/12 properties pass (seed 42): XOR involution + length, hex-key round-trip, `derive_master_key = u32(seed*9+3)` over 2³², `decode_payload` involution, parser/`Mv.decrypt`/`Vxace_key` totality (never throw on arbitrary bytes), `safe_join` containment (Zip-Slip), `choose_output_extension` totality. |
| Mutation testing | done, verified | 7 directed mutants, 7/7 killed after two coverage-gap fixes (see `MUTATION_REPORT.md`). |
| Gospel specs | done, type-check-verified locally; clean exit-0 on Linux CI | Specs on the pure core (see below). Gospel 0.3.1 on Windows/mingw crashes with `output_value: not a binary channel` *after* successful type-checking (a text-mode marshal bug); type errors are reported *before* the crash, so a spec is taken as valid when `gospel check`'s only failure is that crash (sanity-checked with a deliberately erroneous spec). The `ocaml-verification` CI job gives a clean exit 0 on Linux. |
| ortac RAC | not run (tool not applicable) | `ortac qcheck-stm` (ortac 0.8.0) targets *stateful* APIs (needs a `sut`/`init_sut` model); the rpgm-decrypt core is stateless, so it does not apply. The `ortac wrapper` RAC command does not exist in 0.8.0. Runtime contract checking of the Gospel `ensures` is instead provided by the QCheck property suite, which evaluates the same contracts at runtime with 0 violations (e.g. `p_derive_master_key` ↔ `derive_master_key` ensures, `p_safe_join_*` ↔ `safe_join` containment). |
| Why3 + Z3 proofs | done, verified locally (23/23 Valid) | Cameleer is not in the opam repository, so `ocaml-why3-proof` CI job runs a hand-written WhyML model (`proofs/rpgm_proof.mlw`) of the proof targets with the axiomatised helpers **defined** (`read_u32_le`, `u32`, `normalize`), discharged by Z3 (`why3 prove -P z3 -a split_goal_full`). All goals proved: `derive_master_key = u32(seed*9+3)`, `read_u32_le` LE formula, the **Zip-Slip invariant** (normalize never yields a `..` component — a program proof), `read_entry` clamped bounds, parser `pos` in `[0,len]`. See `proofs/README.md` + `proofs/proof_output.txt`. |

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
  contract and are checked at runtime by the QCheck properties / behavioural tests;
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
given deductive specs — they are covered by the behavioural tests and the
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
