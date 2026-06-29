# Contributing to rpgm-decrypt

## Clean-room implementation rule

This project is a **clean-room reimplementation** of publicly documented RPG Maker
asset-decryption algorithms. The byte-level layout of RPG Maker archives is
publicly documented by Kadokawa / Enterbrain (the engine vendor), the
Petschko reference implementation (MIT-licensed), the uuksu RPGMakerDecrypter
reference (MIT-licensed), and the RPG-Maker-Translation-Tools ecosystem
(WTFPL-licensed). The algorithms are not copyrightable.

**All contributors must:**

1. Cite the public source of every algorithm in a code comment (URL, file
   header, magic-byte table line, etc.).
2. **Never copy-paste trunk-sized blocks** (>50 LoC) from Petschko, uuksu, or
   any other reference implementation, even though they are MIT/WTFPL.
3. When in doubt about line-by-line similarity, re-implement from the public
   spec (the engine's own `rpg_core.js` source is the canonical reference for
   MV/MZ) and reference it.

The reason: we want this codebase to remain unambiguously an independent
implementation, not a derivative work, so that the project can be licensed
Apache-2.0 (with patent grant) rather than inheriting any other project's
license obligations.

## Pull-request style

- One logical change per PR.
- Tests for the change must be in the same PR (TDD: failing test → fix → pass).
- Commit messages: imperative mood, present tense, ≤72 chars; body explains
  the WHY.
- Run `dune build --profile release` and `dune exec --profile release test/test.exe` locally before submitting.
- Run `dune build @fmt` (ocamlformat) to keep formatting canonical.

## Format-spec references

When implementing a new format parser, link to one of these in the file:

- **MV / MZ**:  https://rpgmakerweb.com/, public docs; reverse-engineered behaviour
  documented in many community wikis.
- **XP / VX / VX Ace (`.rgssad`, `.rgss2a`, `.rgss3a`)**: format reverse-engineered
  by community; see Petschko/RPG-Maker-MV-Decrypter's `java/`-folder source for the
  reading algorithm.

## Reporting bugs

Please include:

- OS + OCaml version (`ocaml --version`) + dune version.
- RPG Maker game name + engine version (visible in `<game>/www/js/rpg_core.js`
  constants or `package.json` of an MZ game).
- A *small* (≤1 file) reproducer: a game directory tree marked down to one
  problematic asset, with the exact decryption-instruction output.
