(* RGSSAD v1 parser + payload decryptor.

   Used by BOTH RPG Maker XP (`.rgssad`) and VX (`.rgss2a`): the two share one
   on-disk format whose version byte is 0x01. (There is no RGSSAD "v2"; VX Ace's
   `.rgss3a` is v3 and lives in [Vxace].)

   The format is a stream, not a table. A single rolling key is seeded with
   0xDEADCAFE and mutated `key = (key*7 + 3) mod 2^32` after every 32-bit field
   it decrypts and after every individual filename byte. From offset 8 to EOF:

     name_len : u32                (XOR whole key, then advance)
     name     : name_len bytes     (each XOR key&0xff, advance per byte)
     size     : u32                (XOR whole key, then advance)
     data     : size bytes         (left in place; decrypted on demand with the
                                     key value captured right after [size])

   File data is decrypted separately by [decrypt_data]: the per-entry key
   (captured in [entry.key]) advances every 4 bytes and each cipher byte is
   XOR'd with the matching little-endian byte of the current key.

   Length fields are read into OCaml's 63-bit `int`, so a corrupt high-bit
   length stays a large POSITIVE value and is caught by the `pos + n > len`
   bounds checks (Truncated) rather than causing an out-of-bounds access. *)

type entry = { index : int; name : string; offset : int; size : int; key : int }
type parse_error = ShortHeader | BadMagic | BadVersion of int | Truncated

let magic_key = Crypto.magic_rgssad_prefix
let initial_key = 0xDEADCAFE
let u32 (x : int) : int = x land 0xFFFFFFFF
let advance (key : int) : int = u32 ((key * 7) + 3)

let read_u32_le (buf : bytes) (pos : int) : int =
  Char.code (Bytes.get buf pos)
  lor (Char.code (Bytes.get buf (pos + 1)) lsl 8)
  lor (Char.code (Bytes.get buf (pos + 2)) lsl 16)
  lor (Char.code (Bytes.get buf (pos + 3)) lsl 24)

let parse (buf : bytes) : (entry list * int, parse_error) result =
  let len = Bytes.length buf in
  if len < 8 then Error ShortHeader
  else if not (Crypto.starts_with magic_key buf) then Error BadMagic
  else if Char.code (Bytes.get buf 7) <> 0x01 then
    Error (BadVersion (Char.code (Bytes.get buf 7)))
  else begin
    let key = ref initial_key in
    let pos = ref 8 in
    let idx = ref 0 in
    let acc = ref [] in
    let keep = ref true in
    let malformed = ref false in
    while !keep do
      (* need a u32 name_len; otherwise we've reached the end of the stream *)
      if !pos + 4 > len then begin
        if !pos <> len then malformed := true;
        keep := false
      end
      else begin
        let name_len = read_u32_le buf !pos lxor !key in
        key := advance !key;
        pos := !pos + 4;
        if name_len < 0 || !pos + name_len > len then begin
          malformed := true;
          keep := false
        end
        else begin
          let name = Bytes.create name_len in
          for i = 0 to name_len - 1 do
            Bytes.set name i
              (Char.chr (Char.code (Bytes.get buf (!pos + i)) lxor (!key land 0xFF)));
            key := advance !key
          done;
          pos := !pos + name_len;
          if !pos + 4 > len then begin
            if !pos <> len then malformed := true;
            keep := false
          end
          else begin
            let size = read_u32_le buf !pos lxor !key in
            key := advance !key;
            pos := !pos + 4;
            let data_key = !key in
            if size < 0 || !pos + size > len then begin
              malformed := true;
              keep := false
            end
            else begin
              acc :=
                {
                  index = !idx;
                  name =
                    String.map
                      (fun c -> if c = '\\' then '/' else c)
                      (Bytes.to_string name);
                  offset = !pos;
                  size;
                  key = data_key;
                }
                :: !acc;
              incr idx;
              pos := !pos + size
            end
          end
        end
      end
    done;
    if !malformed then Error Truncated
    else match !acc with [] -> Error Truncated | l -> Ok (List.rev l, !pos)
  end

(** Extract raw (still-encrypted) payload bytes for one entry. *)
let read_entry (buf : bytes) (e : entry) : bytes =
  let start = e.offset in
  let len = Bytes.length buf in
  if start < 0 || start >= len || e.size <= 0 then Bytes.create 0
  else begin
    let size = min e.size (len - start) in
    Bytes.sub buf start size
  end

(** Decrypt an entry's payload: XOR each byte with the little-endian byte of the
    running key, advancing `key = key*7+3` every 4 bytes. *)
let decrypt_data (e : entry) (cipher : bytes) : bytes =
  let n = Bytes.length cipher in
  let out = Bytes.make n '\000' in
  let key = ref e.key in
  let j = ref 0 in
  for i = 0 to n - 1 do
    if !j = 4 then begin
      key := advance !key;
      j := 0
    end;
    Bytes.set out i
      (Char.chr (Char.code (Bytes.get cipher i) lxor ((!key lsr (8 * !j)) land 0xFF)));
    incr j
  done;
  out
