# Mutation testing report — OCaml port

Manual smoke mutation campaign (no `mutaml` dependency: a PowerShell driver
applies one mutation at a time, rebuilds, runs the behavioural suite
(`test/test.exe`) and the QCheck property suite (`test/prop/prop.exe`) as the
oracle, records KILLED/SURVIVED, then restores the original source from an
in-memory copy). A mutation is **killed** if either suite exits non-zero.

## Methodology

- Driver: `mutate.ps1` (kept out of the repo; reproducible from this report).
- Oracle: `dune exec test/test.exe` (behavioural, 72 checks) **and**
  `dune exec test/prop/prop.exe` (QCheck2, 12 properties, seed 42).
- Each mutation is a single literal source edit; the driver verifies the
  find-string is present (NOT-APPLIED otherwise) and restores the original
  after the run. A final `git status` confirms a clean lib tree.
- Mutations target the verified pure core: XOR, key derivation, u32 parsing,
  Zip-Slip containment, and the extension dispatcher.

## First wave — 7 mutations

| # | Mutation | build | test | prop | result |
|---|----------|------:|-----:|-----:|--------|
| M1 | `crypto`: xor key index `i mod klen` → `i mod (klen+1)` | 0 | 2 | 1 | KILLED |
| M2 | `crypto`: xor output size `n` → `n+1` | 0 | 1 | 1 | KILLED |
| M3 | `vxace_key`: `derive_master_key` `+3` → `+4` | 0 | 1 | 1 | KILLED |
| M4 | `rgssad_core`: `read_u32_le` byte1 `lsl 8` → `lsl 16` | 0 | 0 | 0 | **SURVIVED** |
| M5 | `report`: `safe_join` `full = root` → `full = full` | NA | NA | NA | NOT-APPLIED |
| M6 | `dispatch`: `choose_output_extension` `png` → `.pngx` | 0 | 0 | 1 | KILLED |
| M7 | `dispatch`: `choose_output_extension` `ogg` → `.png` | 0 | 0 | 0 | **SURVIVED** |

Summary: killed=4, survived=2, not-applied=1.

### Survivor analysis (real coverage gaps found)

- **M4 survived**: `read_u32_le` byte1 shift `lsl 8 → lsl 16` was not detected.
  Root cause: the behavioural tests only round-trip u32 values `< 256`, which fit in
  byte 0, so a wrong shift on bytes 1..3 has no effect. The property tests only
  check totality (no throw), not value correctness. **Gap**: high bytes of u32
  parsing were untested.
- **M7 survived**: `choose_output_extension` mapping `ogg → .png` was not
  detected. Root cause: no test exercises `kind = "ogg"` (or `m4a`/`jpg`); the
  property test only checks the result is *some* valid extension, and `.png` is
  valid. **Gap**: the kind→extension map was not checked per-kind.
- **M5 not-applied**: the find-string `then Some full else None` did not match
  (ocamlformat wraps it across two lines). Reposed the mutation to
  `full = root` (a single-line, unique tautology mutation).

### Fixes (test-suite improvements from the findings)

Added 4 behavioural checks to `test/test.ml`:

- `rgssad read_u32_le 0x12345678` — round-trips a value with non-zero bytes
  1..3, killing M4 and any byte-shift mutation in `read_u32_le`.
- `chooseExt ogg/m4a/jpg kind` — verify each kind maps to its own extension,
  killing M7 and any single-kind mapping swap.

## Second wave — 7 mutations (after the fixes)

| # | Mutation | build | test | prop | result |
|---|----------|------:|-----:|-----:|--------|
| M1 | `crypto`: xor key index `i mod klen` → `i mod (klen+1)` | 0 | 2 | 1 | KILLED |
| M2 | `crypto`: xor output size `n` → `n+1` | 0 | 1 | 1 | KILLED |
| M3 | `vxace_key`: `derive_master_key` `+3` → `+4` | 0 | 1 | 1 | KILLED |
| M4 | `rgssad_core`: `read_u32_le` byte1 `lsl 8` → `lsl 16` | 0 | 1 | 0 | KILLED |
| M5 | `report`: `safe_join` `full = root` → `full = full` | 0 | 2 | 1 | KILLED |
| M6 | `dispatch`: `choose_output_extension` `png` → `.pngx` | 0 | 0 | 1 | KILLED |
| M7 | `dispatch`: `choose_output_extension` `ogg` → `.png` | 0 | 1 | 0 | KILLED |

**Mutation score: 7/7 killed (100%)** after the two targeted test additions.

## Honest scope

This is a 7-mutation directed smoke, not a full mutaml campaign with an
equivalent-mutant analysis. It demonstrates the suite catches representative
operator/bounds/logic mutants on the verified core, and it surfaced (and
closed) two genuine coverage gaps. The I/O modules (`io`, `walk`, `mz`,
`report.run`, `key_discovery`) are not mutated here — they are covered by the
72 behavioural checks + 12 QCheck properties (see the README "Formal
verification & guarantees" section); the deductive proofs target the pure
core, not I/O.
