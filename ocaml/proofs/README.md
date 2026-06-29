# Deductive verification (Why3 + Alt-Ergo)

This directory holds the deductive-verification artefacts for the OCaml pure
core. The proofs run on the `ocaml-why3-proof` GitLab CI job (manual; Linux,
`why3` + `z3`) and locally via:

```sh
opam install why3          # alt-ergo is NOT used (its ocplib-simplex dep fails
                           # to find autoconf on some setups); we use Z3
why3 config detect         # registers the z3 binary
why3 prove -P z3 -a split_goal_full -t 30 ocaml/proofs/rpgm_proof.mlw
```

**Result: all goals discharge (23/23 `Valid`).** The captured prover output is
`proof_output.txt`. The `-a split_goal_full` transformation is required: it
breaks the recursive program-proof VCs into Z3-handleable pieces (without it
Z3 E-matches the `mem` predicate over unbounded lists and OOMs).

## Why hand-written WhyML, not Cameleer?

Cameleer (the OCaml→WhyML translator driven by Gospel specs) is **not in the
opam repository** (`opam search cameleer` → no matches; the package has not
been published to the main repo for the OCaml 5.x era). So we cannot run
`cameleer lib/*.ml` in CI. Instead, `rpgm_proof.mlw` is a hand-written WhyML
model of the three proof-target functions, whose `goal`s/VCs state the **same
contracts** as the Gospel `ensures` in the `.mli` files.

Crucially, the helpers that Gospel 0.3.1 left **uninterpreted** (because it
ships no Bytes/String/Char theory) — `read_u32_le`, `u32`, `normalize` — are
**defined** in the WhyML model. With the helpers defined, the VCs discharge
**unconditionally** (no axiom the prover must trust).

## Modeling note: algebraic path components

`Report.normalize` operates on `string` path components, but Why3's `string` is
abstract and Z3 cannot case-split string values (equality reasoning over
universal strings sends Z3 into an E-matching OOM). The Zip-Slip invariant is
*structural* — "no `..` component after normalize" — independent of what the
other segments spell. So `PathContainment` models components as an algebraic
type `comp = Empty | Dot | DotDot | Seg`, letting Z3 case-split the four
constructors. The invariant is then proved as a **program proof** (`let rec
normalize_acc_proc` with `not (mem DotDot r)` as the postcondition): each VC is
local (Nil branch via the stdlib `reverse_mem` lemma; Cons branch by case
analysis on `seg`/`acc` + the recursive call's ensures as the IH), and
`split_goal_full` splits them into subgoals Z3 discharges.

## Proof targets and status (all discharged by Z3)

| Goal / VC | Contract (matches Gospel `ensures`) | Status |
|---|---|---|
| `RgssadU32.derive_master_key_spec` | `derive_master_key buf off = u32 ((read_u32_le buf off)*9 + 3)` | Valid |
| `RgssadU32.read_u32_le_formula` | little-endian byte expansion | Valid |
| `PathContainment.normalize_acc_proc'vc` | normalize onto a `..`-free accumulator ⇒ `..`-free result (Zip-Slip) — 18 sub-goals (variant, precondition, postcondition) | all Valid |
| `PathContainment.normalize_proc'vc` | `normalize p` has no `..` component | Valid |
| `RgssadBounds.read_entry_size_nonneg` | clamped slice size ≥ 0 (requires `esize ≥ 0`) | Valid |
| `RgssadBounds.read_entry_size_bounded` | clamped slice size ≤ `len` | Valid |
| `RgssadBounds.advance_in_bounds` | parser `pos` stays in `[0,len]` (requires `delta ≥ 0`) | Valid |

The two `requires` clauses added (`esize ≥ 0`, `delta ≥ 0`) are real OCaml
invariants: entry sizes come from `read_u32_le` (≥ 0) and the parser only
advances `pos` forward. They were surfaced by Z3 returning `Unknown (sat)` on
the under-specified versions — a genuine proof finding, not a workaround.

## What is NOT proved here

The I/O modules (`io`, `walk`, `mz`, `report.run`, `log`, `key_discovery`) are
not given deductive specs — they are covered by the 72 parity tests + 12 QCheck
properties (see `ocaml/README.md` "Formal verification & guarantees"). The
WhyML model proves the *contracts* on the pure core; it is not a full
source-faithful translation of the OCaml source (cameleer would provide that,
when it becomes installable). The `path_combine` helper is not modelled
separately: the Zip-Slip invariant is a property of `normalize` alone (the
containment check in `safe_join` is then `full = root || full` starts with
`root+"/"`, guarded by the no-`..` result proven here).

## Gospel upgrade tracking

These items would let us drop the axiomatisation and run `gospel check` cleanly
on Windows, and eventually use cameleer for a full auto-translation:

- **Gospel Bytes/String/Char theories.** Gospel 0.3.1's `Gospelstdlib` ships
  only `Array`/`List`/`Sequence`/`Bag`/`Set`/`Map`/`Sys` + arithmetic — no
  `Bytes`, `String`, or `Char` theory. Adding them would let `xor_transform`,
  `sub_array_eq`, `read_u32_le`, `normalize`, … be specified with *grounded*
  (not uninterpreted) operations, so `gospel check` could type-check them
  without per-file `function` axioms and cameleer could translate them.
- **mingw `output_value` channel fix.** On Windows/mingw, `gospel check` crashes
  with `Failure("output_value: not a binary channel")` *after* successful
  type-checking (it marshals the typed spec to a `.gospel` file via a channel
  opened in text mode). A fix (open the channel binary, or skip the marshal on
  a `check`-only run) would make `gospel check` exit 0 on Windows, removing the
  need to infer validity from "only the marshal crash, no type error".
- **Cameleer published to opam for OCaml 5.x.** When `opam install cameleer`
  works on OCaml 5.3+, the `ocaml-why3-proof` CI job can be replaced by
  `cameleer lib/*.ml` consuming the Gospel specs directly, giving a full
  source-faithful translation rather than the hand-written model here.

Track upstream: https://gitlab.inria.fr/why3/why3 , https://ocamlpro.github.io/gospel/ ,
https://github.com/ocaml-gospel/cameleer .
