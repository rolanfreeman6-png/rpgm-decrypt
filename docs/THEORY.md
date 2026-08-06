# rpgm-decrypt / Theory of operation

A two-page technical brief for the maintainer.

---

## 1. Threat model (what we are *not* trying to do)

rpgm-decrypt is not a DRM cracker. The RPG Maker encryption schemes are
deliberately weak — they protect assets against accidental unpacking, not
against a determined adversary. The key is sitting in plaintext in the
shipped game file (`System.json`). Any user who can run the game can
extract the key.

What we *are* doing: giving modders, translators, and asset-owners a clean
tool to recover their *legitimate* work from RPG Maker archives — for
preservation, localisation, modding, and license-compliance auditing.

If you came here to "remove encryption" from a game you do not own — go
away. We are not helping.

---

## 2. Magic-byte table

```
RPG Maker XP         RGSSAD\x00\x01           + rolling-key XOR stream
RPG Maker VX         RGSSAD\x00\x01           + same v1 format as XP (no 0x02)
RPG Maker VX Ace     RGSSAD\x00\x03           + entries table
RPG Maker MV asset   RPGMV.... (16 B header)  + XOR-encrypted payload
RPG Maker MV (alt)   RPGMZ.... (16 B header)  + XOR-encrypted payload
RPG Maker MZ .pak    ZIP, entries inside      + per-entry MV-scheme encryption
```

PNG-encrypted MV asset: file has a header telling the engine *"I am encrypted;
read 16 bytes, XOR-decrypt them with key, you will get my real PNG header
with `\x89PNG` at start"*. We do exactly that.

OGG-encrypted: same scheme, expected header after decrypt: `"OggS"` ASCII at
byte 0 of payload.

M4A-encrypted: expected header after decrypt: `"ftyp"` ASCII (MP4 family).

WebP-encrypted: expected header: `"RIFF....WEBP"`. We detect this and write
the output as `.webp` even when the input extension was `.png_` (issue
[#40](https://github.com/Petschko/RPG-Maker-MV-Decrypter/issues/40)).

---

## 3. RNG of the XOR-key

The `encryptionKey` field in `System.json` is a 32-char lowercase hex
string — 16 random bytes chosen by the developer at project-creation
time. The MV encryption walks the file byte-by-byte:

```text
for i = 0 to length(file):
    output[i] = file[i] XOR key[i mod 16]
```

(Plus: the first 16 bytes of a *truly* encrypted file have a magic
signature `RPGMV`/`RPGMZ` so the engine knows to decrypt, while
unencrypted PNG-encrypted files start PNG-header `89 50 4E 47 0D 0A 1A
0A...`.)

Because the key is 16 bytes long and the operation is symmetric, the
forward operation == the inverse. There is no separate "decrypt key" —
the same key XORs both ways.

---

## 4. MZ .pak internals

A built MZ game ships with a single `www/packed_<hash>.pak` file inside a
deeper folder named by the project's `rpgmMVOiceFanTrans`-style suffix.

Internals:

- The `.pak` file is a ZIP archive.
- ZIP encryption is **not** used.
- Each entry inside is treated as if it were an individual MV-style
  encrypted asset.

We open it with `System.IO.Compression.ZipArchive`, iterate entries,
apply MV decryption per entry.

---

## 5. RGSSAD walking

XP / VX / VX Ace archives (`RGSSAD`) are a single blob of concatenated,
XOR-encrypted entries. There is no offset/size table: the archive is a
*stream* that must be read front-to-back, and every field — filename
length, filename bytes, payload size, and the payload itself — is
encrypted with a key that rolls forward as you read.

- Header magic: `"RGSSAD\x00"` (7 bytes) + 1 version byte. Only two
  versions exist in the wild: `0x01` (XP `.rgssad` **and** VX `.rgss2a` —
  byte-for-byte the same format) and `0x03` (VX Ace). There is no `0x02`.
- Reference implementation: uuksu/RPGMakerDecrypter
  (`RGSSADv1.cs` / `RGSSADv3.cs`, GPL-3.0) — the canonical description of
  this format.

### v1 — XP `.rgssad` / VX `.rgss2a` (`0x01`)

A rolling 32-bit key is seeded at `0xDEADCAFE` and advanced by
`key = (key * 7 + 3) mod 2^32` after **every** u32 field read and after
**every** filename byte. Each entry, in order, is:

```
name_len : u32   XOR key            (then advance key)
name     : name_len bytes           (each byte XOR (key & 0xFF), advance key per byte)
data_len : u32   XOR key            (then advance key)
data     : data_len bytes           (payload — see below)
```

The payload key is the value of the rolling key *captured immediately
after reading `data_len`*. The payload is decrypted by XORing against the
little-endian bytes of that key, advancing the key with the same
`*7+3` rule once every 4 payload bytes. The stream ends when the fields
would run past EOF; a well-formed archive lands exactly on the last
entry's final payload byte.

Unlike VX Ace, the v1 payload is *not* separately zlib-deflated by the
format — the decrypted bytes are the original file (`.rxdata` / `.rvdata`
Ruby `Marshal` data, PNGs, etc.), which we write out per entry.

### v3 — VX Ace (`0x03`)

A 4-byte master seed follows the header at byte 8;
`masterKey = seed * 9 + 3`. Each entry is
`offset(4) | size(4) | entry_key(4) | name_len(4) | name(name_len)`,
where all four u32 fields are XOR-decrypted with `masterKey`, `name` is
XOR-decrypted with the 4 LE bytes of `masterKey` (cycling), and the loop
ends when a decrypted `offset` is `0`. Each entry's payload is encrypted
with a per-entry rotating key (`tempKey = tempKey * 7 + 3` every 4 bytes),
which we decrypt and write out per entry.

---

## 6. Key recovery walk (in order)

```
1. <game_dir>/www/js/System.json   — JSON, read "encryptionKey" hex, decode.
2. <game_dir>/www/data/System.json — same; this is the deployed (NW.js/Steam/
   itch.io) layout, tried before giving up on System.json.
3. <game_dir>/www/js/rpg_core.js   — regex scan for a 32-hex-char literal:
     Decrypter._encryptionKey = ["\x", "<32 hex>"      (rpg_core shape)
     encryptionKey = "<32 hex>"                        (fallback shape)
4. Every *.js under www/js, then every *.js under www/ (AllDirectories) —
   same regex scan, first hit wins.
5. If none match: exit 4 with a clear message (supply --password /
   --password-file / --vxace-seed).
```

We never evaluate JavaScript — only extract string literals.

---

## 7. Output scheme

We mirror the input structure. If game_dir is:

```
<game>/
  www/
    img/
      Characters/
        $Hero.png_
        $Hero.png        (unencrypted PNG, leave alone)
    audio/
      bgm/
        Theme.ogg_
    System.json
```

…then out_dir becomes:

```
<out>/
  www/
    img/
      Characters/
        $Hero.png        (decrypted)
    audio/
      bgm/
        Theme.ogg        (decrypted)
```

For XP / VX / VX Ace archives every entry is decrypted and written out to
its in-archive path under the mirror tree (e.g. `Data/Actors.rvdata2`),
so the archive is fully expanded rather than merely listed. The per-run
summary is printed to **stdout** (`--report-format human|json`); per-file
progress events go to **stderr** (`--log-format human|json`). No extra
bookkeeping files are written to `out_dir` beyond the decrypted assets.

Unencrypted files are detected (`RPGMV`/`RPGMZ` bytes absent, magic
pre-XOR-decrypt matches PNG/OGG/M4A/WebP/JPG signature) and copied
through unchanged.

---

## 8. Security posture

- We do not auto-execute Ruby Marshal `rvdata` / `rvdata2` payloads.
  Even if an archive entry is "supposed to be" a Ruby object stream
  carrying live bytecode instructions, we treat it as opaque bytes.
- We use tight loops in the MV/MZ hot path: one output `byte[]` is
  allocated per file and the XOR runs a single pass over it (the key
  bytes for the VX Ace stream cipher are extracted by shift/mask, not
  re-allocated per byte).
- Key bytes are zeroized after use via `Crypto.zeroFill` (called from
  `the CLI module` once the run completes).

### Formally verified guarantees (Why3 + Z3, `proofs/rpgm_proof.mlw`)

The pure core carries machine-checked proofs (103/103 goals `Valid`; see
`ocaml/proofs/`). What is *proved* vs. what is *validated empirically*:

- **Proved (format-independent — hold on any input, including hostile bytes):**
  no out-of-bounds read and guaranteed termination of the `Rgssad_core.parse`
  and `Vxace.parse` entry loops (source-faithful WhyML transcriptions, with a
  lexicographic `variant` and `0 ≤ end_pos ≤ len` postcondition); a corrupt
  high-bit length stays a positive 32-bit int and is caught by the bounds check
  (`read_u32_le_range`); the stream-cipher **involution** (encrypt∘decrypt = id,
  because the keystream is a pure function of position, proved over `BV8`/`BV32`);
  `derive_master_key = u32(seed*9+3)`; and the Zip-Slip invariant on `normalize`.
- **Validated empirically (format-dependent — that the algorithm matches *real*
  archives):** the Track-0 golden tests (`test/test.ml`, `RPGM_FIXTURES_DIR`)
  decrypt real XP/VX/VX Ace reference archives and check the recovered TOC and
  Ruby `Marshal` (`\x04\x08`) payloads byte-for-byte. This — not the proofs —
  is what confirms the descriptor formula itself.
