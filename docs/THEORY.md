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
RPG Maker XP         RGSSAD\x00\x01           + filename-encrypted-as-XOR
RPG Maker VX         RGSSAD\x00\x02           + entries table
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

XP/VX/VXAce archives are simpler: file entries are keyed by offset/size
table, but the *filenames* are XOR-obfuscated with a key derived from the
archive's own header.

Concretely:

- Header magic: `"RGSSAD\x00"` (7 bytes).
- Then a version byte: `0x01` (XP), `0x02` (VX), `0x03` (VX Ace).
- Then entries:
  - For XP (`0x01`): each entry is `<size_le:u32><offset_le:u32><name_len:u32><name_bytes:...zip?>`.
    The `name_bytes` are XOR-obfuscated with the RGSSAD magic, not the key
    we control. We decode it on the fly using the magic bytes as the key.
  - For VX/VXAce (`0x02`/`0x03`): each entry is `<name_len:u32><name_bytes:...><size:u32><offset:u32>`.
    Same XOR on `name_bytes` using the RGSSAD magic.

The *file contents* themselves are not encrypted — only the *filenames*
are. Standard zip-deflate compression is applied separately.

---

## 6. Key recovery walk (in order)

```
1. Hit <game_dir>/www/js/System.json
   Read JSON, find "encryptionKey": "..."(hex string), decode.
2. If not found, hit <game_dir>/www/js/rpg_core.js
   Regex scan for: /Decrypter\._encryptionKey\s*=\s*\[[^\]]*\]/
                     /Decrypter\.hasEncryptedImages\s*=\s*true/
                     /dataSystem\.encryptionKey\s*=\s*["'][^"']+["']/
   Try to parse whichever matched into bytes.
3. If not found, hit all *.js under <game_dir>/www/js/
   Same regex scan, walk every file.
4. If not found: abort with non-zero exit code and a clear message.
```

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
  _manifest.json         (per-run summary)
  _report.txt            (human summary if --report-format human)
  _failures.jsonl        (NDJSON of every Failed entry)
```

Unencrypted files are detected (`RPGMV`/`RPGMZ` bytes absent, magic
pre-XOR-decrypt matches PNG/OGG/M4A/WebP/JPG signature) and copied
through unchanged.

---

## 8. Security posture

- We do not auto-execute Ruby Marshal `rvdata` / `rvdata2` payloads.
  Even if an archive entry is "supposed to be" a Ruby object stream
  carrying live bytecode instructions, we treat it as opaque bytes.
- We use `noalloc`-style tight loops in MV/MZ hot path. The byte
  arithmetic is the only place GC pressure would matter, and we
  pre-allocate `byte[]` arrays once per file.
- Key bytes are zeroized after use (F# `Array.zeroCreate` + manual
  fill via `Mutables.fill` API in `Crypto.fs`).
