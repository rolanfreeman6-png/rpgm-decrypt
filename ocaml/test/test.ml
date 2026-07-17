(* In-process test runner: 72 behavioural checks over crypto, parsers, MZ,
   end-to-end Report.run, safe_join, and read_u32_le. *)

open Rpgm

let total = ref 0
let passed = ref 0
let fails : string list ref = ref []

let check name cond =
  incr total;
  if cond then incr passed else fails := name :: !fails

let check_bytes name a b = check name (Bytes.equal a b)

let bytes_of_hex h =
  (* even-length hex -> bytes *)
  let n = String.length h / 2 in
  Bytes.init n (fun i ->
      let hx c = Crypto.hex_nibble (Char.lowercase_ascii c) in
      Char.chr ((hx h.[2 * i] lsl 4) lor hx h.[(2 * i) + 1]))

let raises f =
  try
    ignore (f ());
    false
  with _ -> true

let set_u32le b pos v =
  Bytes.set b pos (Char.chr (v land 0xFF));
  Bytes.set b (pos + 1) (Char.chr ((v lsr 8) land 0xFF));
  Bytes.set b (pos + 2) (Char.chr ((v lsr 16) land 0xFF));
  Bytes.set b (pos + 3) (Char.chr ((v lsr 24) land 0xFF))

(* ---- Crypto ---------------------------------------------------------- *)
let test_crypto () =
  let k = Crypto.decode_hex_key "0123456789abcdef0123456789abcdef" in
  check "decodeHexKey b0" (Bytes.get k 0 = '\x01');
  check "decodeHexKey b15" (Bytes.get k 15 = '\xef');
  let key = Bytes.of_string "\x01\x02\x03\x04\x05" in
  let orig = Bytes.of_string "\x42\x00\xff\xaa\x55\xc3\x11" in
  check_bytes "xor involution" orig
    (Crypto.xor_transform key (Crypto.xor_transform key orig));
  check "looksLikePlaintext png"
    (Crypto.looks_like_plaintext (bytes_of_hex "89504E470D0A1A0A"));
  check "looksLikePlaintext ogg"
    (Crypto.looks_like_plaintext (Bytes.of_string "OggSxxxx"));
  check "looksLikePlaintext jpg"
    (Crypto.looks_like_plaintext (Bytes.of_string "\xff\xd8\xff\xe0"));
  check "looksLikePlaintext rejects RPGMV"
    (not (Crypto.looks_like_plaintext (Bytes.of_string "RPGMV3123456789012")));
  check "decodeHexKey rejects short"
    (raises (fun () -> Crypto.decode_hex_key "abcd"));
  check "decodeHexKey rejects non-hex"
    (raises (fun () -> Crypto.decode_hex_key "zz23456789abcdef0123456789abcdef"));
  check "xorTransform rejects empty key"
    (raises (fun () ->
         Crypto.xor_transform (Bytes.create 0) (Bytes.of_string "ab")))

(* ---- Mv -------------------------------------------------------------- *)
let test_mv () =
  let key = bytes_of_hex "123456789ABCDEF01122334455667788" in
  let png = bytes_of_hex "89504E470D0A1A0A0000000D49484452" in
  (match Mv.decrypt key png with
  | Mv.Plaintext (k, b) ->
      check "mv plaintext kind png" (k = "png");
      check_bytes "mv plaintext bytes" png b
  | _ -> check "mv plaintext outcome" false);
  let cipher = Crypto.xor_transform key png in
  check "mv cipher not plaintext" (not (Crypto.looks_like_plaintext cipher));
  (match Mv.decrypt key cipher with
  | Mv.Decrypted (k, b) ->
      check "mv decrypted kind png" (k = "png");
      check_bytes "mv decrypted bytes" png b
  | _ -> check "mv decrypted outcome" false);
  match Mv.decrypt (Bytes.make 16 '\000') cipher with
  | Mv.Unsure _ -> check "mv wrong key -> Unsure" true
  | _ -> check "mv wrong key -> Unsure" false

(* ---- MV real RPG Maker format: 16-byte header + first-16 XOR --------- *)
let test_mv_real_format () =
  let key = bytes_of_hex "d41d8cd98f00b204e9800998ecf8427e" in
  (* a plaintext PNG longer than 16 bytes so we exercise header + tail *)
  let png =
    bytes_of_hex
      "89504E470D0A1A0A0000000D49484452000000100000001008060000001FF3FF61"
  in
  (* build the encrypted asset exactly as RPG Maker does *)
  let hdr = bytes_of_hex "5250474d560000000003010000000000" in
  let enc_body = Bytes.copy png in
  for i = 0 to 15 do
    Bytes.set enc_body i
      (Char.chr
         (Char.code (Bytes.get enc_body i) lxor Char.code (Bytes.get key i)))
  done;
  let cipher = Bytes.cat hdr enc_body in
  check "mv real: header detected"
    (not (Crypto.looks_like_plaintext cipher));
  (match Mv.decrypt key cipher with
  | Mv.Decrypted (k, b) ->
      check "mv real: kind png" (k = "png");
      check "mv real: header stripped (size)" (Bytes.length b = Bytes.length png);
      check_bytes "mv real: exact roundtrip" png b
  | _ -> check "mv real: decrypted outcome" false);
  (* an RPGMZ-headered asset must be handled the same way *)
  let hdr_mz = bytes_of_hex "5250474d5a0000000003010000000000" in
  let cipher_mz = Bytes.cat hdr_mz enc_body in
  match Mv.decrypt key cipher_mz with
  | Mv.Decrypted (_, b) -> check_bytes "mv real: RPGMZ header roundtrip" png b
  | _ -> check "mv real: RPGMZ decrypted" false

(* ---- XP / VX (shared Rgssad_core) ------------------------------------ *)
let build_rgssad ver =
  let name = "Graphics/Hero.png" in
  let nlen = String.length name in
  let enc =
    Bytes.init nlen (fun i ->
        Char.chr
          (Char.code name.[i]
          lxor Char.code (Bytes.get Crypto.magic_rgssad_prefix (i mod 7))))
  in
  let payload = Bytes.init 8 (fun i -> Char.chr i) in
  let psize = Bytes.length payload in
  let pos_payload = 8 + 12 + nlen + 12 in
  let total = pos_payload + psize in
  let buf = Bytes.make total '\000' in
  Bytes.blit Crypto.magic_rgssad_prefix 0 buf 0 7;
  Bytes.set buf 7 (Char.chr ver);
  set_u32le buf 8 psize;
  (* size *)
  set_u32le buf 12 pos_payload;
  (* offset *)
  set_u32le buf 16 nlen;
  (* name_len *)
  Bytes.blit enc 0 buf 20 nlen;
  (* terminator 12 zero bytes already in place *)
  Bytes.blit payload 0 buf pos_payload psize;
  (buf, name, payload, pos_payload)

let test_xp_vx () =
  (* XP v1 *)
  let buf, name, payload, pos_payload = build_rgssad 0x01 in
  (match Xp.parse buf with
  | Ok (entries, _) ->
      check "xp 1 entry" (List.length entries = 1);
      let e = List.hd entries in
      check "xp name" (e.Rgssad_core.name = name);
      check "xp size" (e.Rgssad_core.size = Bytes.length payload);
      check "xp offset" (e.Rgssad_core.offset = pos_payload);
      check_bytes "xp readEntry" payload (Xp.read_entry buf e)
  | Error _ -> check "xp parse ok" false);
  check "xp bad magic"
    (match Xp.parse (Bytes.of_string "\xff\xff\xff\xff\xff\xff\xff\x01") with
    | Error Rgssad_core.BadMagic -> true
    | _ -> false);
  check "xp bad version"
    (match Xp.parse (Bytes.of_string "\x52\x47\x53\x53\x41\x44\x00\x02") with
    | Error (Rgssad_core.BadVersion 2) -> true
    | _ -> false);
  (* VX v2 *)
  let buf2, name2, _, _ = build_rgssad 0x02 in
  (match Vx.parse buf2 with
  | Ok (entries, _) ->
      check "vx 1 entry" (List.length entries = 1);
      check "vx name" ((List.hd entries).Rgssad_core.name = name2)
  | Error _ -> check "vx parse ok" false);
  check "vx bad version"
    (match Vx.parse (Bytes.of_string "\x52\x47\x53\x53\x41\x44\x00\x01") with
    | Error (Rgssad_core.BadVersion 1) -> true
    | _ -> false);
  (* I-1 regression: high-bit name_len must yield Truncated, never crash.
     20-byte buffer: header(8) + size(nonzero,4) + offset(4) + name_len(4). *)
  let bad = Bytes.make 20 '\000' in
  Bytes.blit Crypto.magic_rgssad_prefix 0 bad 0 7;
  Bytes.set bad 7 '\x02';
  set_u32le bad 8 0x10;
  (* size nonzero -> not the sentinel *)
  set_u32le bad 16 0xFFFFFFFA;
  (* name_len high-bit *)
  check "vx high-bit name_len -> Truncated"
    (match Vx.parse bad with Error Rgssad_core.Truncated -> true | _ -> false);
  (* read_u32_le must decode all four bytes; a value > 255 exercises bytes 1..3.
     Mutation coverage: a byte1/byte2 shift mutation survives if only small
     (< 256) values are tested. *)
  let b32 = Bytes.make 4 '\000' in
  set_u32le b32 0 0x12345678;
  check "rgssad read_u32_le 0x12345678"
    (Rgssad_core.read_u32_le b32 0 = 0x12345678)

(* ---- VX Ace ---------------------------------------------------------- *)
let test_vxace () =
  let master = 3 in
  (* seed 0 -> 0*9+3 *)
  let enc_u32 d = d lxor master in
  let name = "Hero.png" in
  let nlen = String.length name in
  let plain_payload = Bytes.init 16 (fun i -> Char.chr (i + 1)) in
  let cipher_payload = Vxace_key.decode_payload plain_payload 0 in
  (* entry_key=0; XOR keystream is involutive *)
  let psize = Bytes.length cipher_payload in
  let pos_payload = 12 + 16 + nlen + 16 in
  let total = pos_payload + psize in
  let buf = Bytes.make total '\000' in
  Bytes.blit Crypto.magic_rgssad_prefix 0 buf 0 7;
  Bytes.set buf 7 '\x03';
  (* seed = 0 at 8..11 already *)
  set_u32le buf 12 (enc_u32 pos_payload);
  (* offset *)
  set_u32le buf 16 (enc_u32 psize);
  (* size *)
  set_u32le buf 20 (enc_u32 0);
  (* entry key *)
  set_u32le buf 24 (enc_u32 nlen);
  (* name_len *)
  (* name encoded with master-key 4-byte cycling (master=3 -> kb [3,0,0,0]) *)
  for i = 0 to nlen - 1 do
    let kb = Vxace_key.key_byte master (i mod 4) in
    Bytes.set buf (28 + i) (Char.chr (Char.code name.[i] lxor kb))
  done;
  (* terminator at 28+nlen: offset decodes 0 -> write enc_u32 0 = 3 *)
  set_u32le buf (28 + nlen) (enc_u32 0);
  Bytes.blit cipher_payload 0 buf pos_payload psize;
  (match Vxace.parse buf with
  | Ok entries ->
      check "vxace 1 entry" (List.length entries = 1);
      let e = List.hd entries in
      check "vxace name" (e.Vxace.name = name);
      check "vxace size" (e.Vxace.size = psize);
      let sliced = Vxace.read_entry buf e in
      check_bytes "vxace payload roundtrip" plain_payload
        (Vxace.decrypt_payload e sliced)
  | Error _ -> check "vxace parse ok" false);
  check "vxace bad version"
    (match
       Vxace.parse
         (Bytes.of_string "\x52\x47\x53\x53\x41\x44\x00\x01\x00\x00\x00\x00")
     with
    | Error (Vxace.BadVersion 1) -> true
    | _ -> false);
  (* master-key formula *)
  check "deriveMasterKey seed0"
    (Vxace_key.derive_master_key (Bytes.make 4 '\000') 0 = 3)

(* ---- MZ (.pak via camlzip) ------------------------------------------- *)
let test_mz () =
  let key = bytes_of_hex "DEADBEEFCAFEBABE0102030405060708" in
  let png = bytes_of_hex "89504E470D0A1A0AAABBCCDDEEFF1122" in
  let cipher = Crypto.xor_transform key png in
  let pak = Filename.temp_file "rpgm" ".pak" in
  let z = Zip.open_out pak in
  Zip.add_entry (Bytes.to_string cipher) z "www/img/test.png";
  Zip.close_out z;
  (match Mz.open_pak pak with
  | Ok zf -> (
      (match Mz.decrypt_all key zf with
      | Ok [ e ] ->
          check "mz entry name" (e.Mz.entry_name = "www/img/test.png");
          check "mz kind png" (e.Mz.plaintext_kind = "png");
          check_bytes "mz bytes" png e.Mz.bytes
      | _ -> check "mz decryptAll 1 entry" false);
      try Zip.close_in zf with _ -> ())
  | Error _ -> check "mz openPak" false);
  check "mz rejects non-zip"
    (match Mz.open_pak Sys.argv.(0) with
    | Error Mz.NotAZipFile -> true
    | Ok _ ->
        check "" true;
        false
    | Error _ -> false);
  Sys.remove pak

(* ---- safe_join + end-to-end Report.run ------------------------------- *)
let test_report () =
  (* safe_join *)
  check "safeJoin nested allowed"
    (Report.safe_join "/tmp/out" "www/img/a.png" <> None);
  check "safeJoin traversal blocked"
    (Report.safe_join "/tmp/out" "../../evil.txt" = None);
  (* MV end-to-end round-trip *)
  let root = Filename.temp_dir "rpgm" "e2e" in
  let game = Filename.concat root "game" in
  Report.mkdir_p (Filename.concat (Filename.concat game "www") "js");
  Report.mkdir_p (Filename.concat (Filename.concat game "www") "img");
  Io.write_file
    (Filename.concat
       (Filename.concat (Filename.concat game "www") "js")
       "System.json")
    (Bytes.of_string {|{ "encryptionKey": "deadbeef00112233445566778899aabb" }|});
  let key = Crypto.decode_hex_key "deadbeef00112233445566778899aabb" in
  let png = bytes_of_hex "89504E470D0A1A0A0000000D49484452AABBCC" in
  Io.write_file
    (Filename.concat
       (Filename.concat (Filename.concat game "www") "img")
       "Hero.png_")
    (Crypto.xor_transform key png);
  let out = Filename.concat root "out" in
  let summary =
    Report.run
      {
        Report.game_dir = game;
        out_dir = out;
        key;
        key_source = "test";
        dry_run = false;
        mirror = false;
        on_event = (fun _ -> ());
      }
  in
  check "e2e failed=0" (summary.Types.failed_count = 0);
  let hero =
    Filename.concat
      (Filename.concat (Filename.concat out "www") "img")
      "Hero.png"
  in
  check "e2e Hero.png exists" (Sys.file_exists hero);
  if Sys.file_exists hero then
    check_bytes "e2e roundtrip" png (Io.read_file hero);
  (* MZ Zip-Slip blocked end-to-end *)
  let game2 = Filename.concat root "game2" in
  Report.mkdir_p game2;
  let cipher =
    Crypto.xor_transform key (bytes_of_hex "89504E470D0A1A0A0000000D49484452")
  in
  let pak = Filename.concat game2 "packed.pak" in
  let z = Zip.open_out pak in
  Zip.add_entry (Bytes.to_string cipher) z "../evil.png";
  Zip.close_out z;
  let out2 = Filename.concat root "out2" in
  let s2 =
    Report.run
      {
        Report.game_dir = game2;
        out_dir = out2;
        key;
        key_source = "test";
        dry_run = false;
        mirror = false;
        on_event = (fun _ -> ());
      }
  in
  check "zipslip counted failed" (s2.Types.failed_count >= 1);
  check "zipslip nothing escaped"
    (not (Sys.file_exists (Filename.concat root "evil.png")))

(* ---- helpers for the expanded suite ---------------------------------- *)
let contains hay needle =
  let hl = String.length hay and nl = String.length needle in
  let rec go i = i + nl <= hl && (String.sub hay i nl = needle || go (i + 1)) in
  nl = 0 || go 0

let write_tmp suffix (content : bytes) =
  let p = Filename.temp_file "rpgm" suffix in
  Io.write_file p content;
  p

(* ---- crypto extras + choose_output_extension ------------------------- *)
let test_crypto_more () =
  check "looksLikePlaintext webp"
    (Crypto.looks_like_plaintext
       (Bytes.of_string "RIFF\x00\x00\x00\x00WEBPxxxx"));
  check "looksLikePlaintext m4a"
    (Crypto.looks_like_plaintext (Bytes.of_string "\x00\x00\x00\x18ftypM4A "));
  check "zero_fill clears"
    (let b = Bytes.of_string "abc" in
     Crypto.zero_fill b;
     Bytes.equal b (Bytes.make 3 '\000'));
  check "chooseExt png_ bin"
    (Dispatch.choose_output_extension ".png_" "bin" = ".png");
  check "chooseExt webp kind"
    (Dispatch.choose_output_extension ".png_" "webp" = ".webp");
  check "chooseExt unknown"
    (Dispatch.choose_output_extension ".xyz" "bin" = ".bin");
  check "chooseExt ogg kind"
    (Dispatch.choose_output_extension ".ogg_" "ogg" = ".ogg");
  check "chooseExt m4a kind"
    (Dispatch.choose_output_extension ".m4a_" "m4a" = ".m4a");
  check "chooseExt jpg kind"
    (Dispatch.choose_output_extension ".jpg" "jpg" = ".jpg")

(* ---- Dispatch.classify (extension + magic) --------------------------- *)
let test_classify () =
  let key = bytes_of_hex "deadbeef00112233445566778899aabb" in
  let png_ =
    write_tmp ".png_"
      (Crypto.xor_transform key
         (bytes_of_hex "89504E470D0A1A0A0000000D49484452"))
  in
  check "classify .png_ -> MV" (Dispatch.classify png_ = Some Types.MV);
  Sys.remove png_;
  let png =
    write_tmp ".png" (bytes_of_hex "89504E470D0A1A0A0000000D49484452")
  in
  check "classify .png -> MV" (Dispatch.classify png = Some Types.MV);
  Sys.remove png;
  let r1 =
    write_tmp ".rgssad" (Bytes.of_string "\x52\x47\x53\x53\x41\x44\x00\x01")
  in
  check "classify .rgssad v1 -> XP" (Dispatch.classify r1 = Some Types.XP);
  Sys.remove r1;
  let r2 =
    write_tmp ".rgssad" (Bytes.of_string "\x52\x47\x53\x53\x41\x44\x00\x02")
  in
  check "classify .rgssad v2 -> VX" (Dispatch.classify r2 = Some Types.VX);
  Sys.remove r2;
  let r3 =
    write_tmp ".rgss3a"
      (Bytes.of_string "\x52\x47\x53\x53\x41\x44\x00\x03\x00\x00\x00\x00")
  in
  check "classify .rgss3a -> VXAce" (Dispatch.classify r3 = Some Types.VXAce);
  Sys.remove r3;
  let zp = write_tmp ".bin" (Bytes.of_string "PK\x03\x04stuffstuff") in
  check "classify zip magic -> MZ" (Dispatch.classify zp = Some Types.MZ);
  Sys.remove zp;
  (* a real MZ `.pak` is a ZIP -> MZ; a NW.js/Chromium `.pak` (no ZIP magic,
     it starts with a version word) is NOT ours -> None (skipped, not failed) *)
  let pak_zip = write_tmp ".pak" (Bytes.of_string "PK\x03\x04stuffstuff") in
  check "classify .pak (zip) -> MZ" (Dispatch.classify pak_zip = Some Types.MZ);
  Sys.remove pak_zip;
  let pak_nwjs =
    write_tmp ".pak"
      (Bytes.of_string "\x04\x00\x00\x00\x01\x00\x00\x00chrome resource pak")
  in
  check "classify .pak (non-zip NW.js) -> None"
    (Dispatch.classify pak_nwjs = None);
  Sys.remove pak_nwjs;
  let no = write_tmp ".bin" (Bytes.of_string "not a game file here") in
  check "classify unknown -> None" (Dispatch.classify no = None);
  Sys.remove no

(* ---- KeyDiscovery ---------------------------------------------------- *)
let test_key_discovery () =
  let root = Filename.temp_dir "rpgm" "kd" in
  let wwwjs = Filename.concat (Filename.concat root "www") "js" in
  let wwwimg = Filename.concat (Filename.concat root "www") "img" in
  Report.mkdir_p wwwjs;
  Report.mkdir_p wwwimg;
  Io.write_file
    (Filename.concat wwwjs "System.json")
    (Bytes.of_string {|{ "encryptionKey": "deadbeef00112233445566778899aabb" }|});
  (match Key_discovery.discover root with
  | Key_discovery.Found (b, src) ->
      check "kd found b0" (Bytes.get b 0 = '\xde');
      check "kd source mentions System.json" (contains src "System.json")
  | _ -> check "kd discover found" false);
  let key = Crypto.decode_hex_key "deadbeef00112233445566778899aabb" in
  let png = bytes_of_hex "89504E470D0A1A0A0000000D49484452" in
  Io.write_file
    (Filename.concat wwwimg "Hero.png_")
    (Crypto.xor_transform key png);
  (match
     Key_discovery.discover_with_wordlist root
       [|
         "00000000000000000000000000000000"; "deadbeef00112233445566778899aabb";
       |]
   with
  | Key_discovery.Found (b, _) -> check_bytes "kd wordlist correct key" key b
  | _ -> check "kd wordlist found" false);
  check "kd empty wordlist rejected"
    (match Key_discovery.discover_with_wordlist root [||] with
    | Key_discovery.NotFound _ -> true
    | _ -> false);
  (* newer MZ layout: data/System.json directly in game dir, no www/ *)
  let mz_root = Filename.temp_dir "rpgm" "kdmz" in
  Report.mkdir_p (Filename.concat mz_root "data");
  Io.write_file
    (Filename.concat (Filename.concat mz_root "data") "System.json")
    (Bytes.of_string {|{ "encryptionKey": "deadbeef00112233445566778899aabb" }|});
  match Key_discovery.discover mz_root with
  | Key_discovery.Found (b, _) ->
      check "kd MZ root layout (no www)" (Bytes.get b 0 = '\xde')
  | _ -> check "kd MZ root layout found" false

(* ---- MZ multi-entry order ------------------------------------------- *)
let test_mz_multi () =
  let key = bytes_of_hex "DEADBEEFCAFEBABE0102030405060708" in
  let png = bytes_of_hex "89504E470D0A1A0AAABBCCDDEEFF1122" in
  let pak = Filename.temp_file "rpgm" ".pak" in
  let z = Zip.open_out pak in
  Zip.add_entry
    (Bytes.to_string (Crypto.xor_transform key png))
    z "www/img/a.png";
  Zip.add_entry
    (Bytes.to_string (Crypto.xor_transform key png))
    z "www/img/b.png";
  Zip.close_out z;
  (match Mz.open_pak pak with
  | Ok zf -> (
      (match Mz.decrypt_all key zf with
      | Ok es ->
          check "mz 2 entries" (List.length es = 2);
          check "mz order a,b"
            (match es with
            | a :: b :: _ ->
                a.Mz.entry_name = "www/img/a.png"
                && b.Mz.entry_name = "www/img/b.png"
            | _ -> false);
          check_bytes "mz entry a bytes" png (List.hd es).Mz.bytes
      | _ -> check "mz multi decryptAll" false);
      try Zip.close_in zf with _ -> ())
  | _ -> check "mz multi openPak" false);
  Sys.remove pak

(* ---- Log escape + JSON ---------------------------------------------- *)
let test_log () =
  check "log escape quote/backslash" (Log.escape "a\"b\\c" = "a\\\"b\\\\c");
  check "log escape newline" (Log.escape "a\nb" = "a\\nb");
  let s = Types.run_summary_empty 0.0 in
  let s =
    {
      s with
      Types.inputs_scanned = 3;
      decrypted_count = 2;
      per_format = [ (Types.MV, 2) ];
    }
  in
  let j = Log.summary_to_json s in
  check "log json MV:2" (contains j "\"MV\":2");
  check "log json scanned:3" (contains j "\"scanned\":3")

(* ---- mirror mode (full playable copy) -------------------------------- *)
let test_mirror () =
  let root = Filename.temp_dir "rpgm" "mirror" in
  let game = Filename.concat root "game" in
  let www = Filename.concat game "www" in
  let js = Filename.concat www "js" in
  let img = Filename.concat www "img" in
  let data = Filename.concat www "data" in
  Report.mkdir_p js;
  Report.mkdir_p img;
  Report.mkdir_p data;
  (* System.json with the key AND encryption flags set to true *)
  Io.write_file (Filename.concat js "System.json")
    (Bytes.of_string
       {|{ "encryptionKey": "deadbeef00112233445566778899aabb", "hasEncryptedImages": true, "hasEncryptedAudio": true }|});
  (* an extraneous non-asset file that must be copied verbatim *)
  let map_body = Bytes.of_string {|{"events":[1,2,3],"note":"keep me"}|} in
  Io.write_file (Filename.concat data "Map001.json") map_body;
  let key = Crypto.decode_hex_key "deadbeef00112233445566778899aabb" in
  let png = bytes_of_hex "89504E470D0A1A0A0000000D49484452AABBCC" in
  Io.write_file
    (Filename.concat img "Hero.png_")
    (Crypto.xor_transform key png);
  (* also a .rpgmvp asset (this codebase's model: whole-file cyclic XOR) —
     must be renamed to .png in the copy, not left as .rpgmvp *)
  Io.write_file
    (Filename.concat img "Actor1.rpgmvp")
    (Crypto.xor_transform key png);
  let out = Filename.concat root "out" in
  let summary =
    Report.run
      {
        Report.game_dir = game;
        out_dir = out;
        key;
        key_source = "test";
        dry_run = false;
        mirror = true;
        on_event = (fun _ -> ());
      }
  in
  check "mirror failed=0" (summary.Types.failed_count = 0);
  let out_www = Filename.concat out "www" in
  (* extraneous file copied byte-for-byte *)
  let map_out =
    Filename.concat (Filename.concat out_www "data") "Map001.json"
  in
  check "mirror copies extraneous json" (Sys.file_exists map_out);
  if Sys.file_exists map_out then
    check_bytes "mirror extraneous untouched" map_body (Io.read_file map_out);
  (* asset decrypted *)
  let hero = Filename.concat (Filename.concat out_www "img") "Hero.png" in
  check "mirror Hero.png exists" (Sys.file_exists hero);
  if Sys.file_exists hero then
    check_bytes "mirror roundtrip" png (Io.read_file hero);
  (* stale encrypted twin removed *)
  let hero_enc = Filename.concat (Filename.concat out_www "img") "Hero.png_" in
  check "mirror stale twin removed" (not (Sys.file_exists hero_enc));
  (* .rpgmvp renamed to .png, and its encrypted twin removed *)
  let actor_png =
    Filename.concat (Filename.concat out_www "img") "Actor1.png"
  in
  let actor_enc =
    Filename.concat (Filename.concat out_www "img") "Actor1.rpgmvp"
  in
  check "mirror rpgmvp -> png" (Sys.file_exists actor_png);
  check "mirror rpgmvp twin removed" (not (Sys.file_exists actor_enc));
  (* System.json encryption flags cleared *)
  let sys_out =
    Bytes.to_string
      (Io.read_file (Filename.concat (Filename.concat out_www "js") "System.json"))
  in
  check "mirror clears hasEncryptedImages"
    (contains sys_out "\"hasEncryptedImages\": false");
  check "mirror clears hasEncryptedAudio"
    (contains sys_out "\"hasEncryptedAudio\": false");
  check "mirror keeps encryptionKey" (contains sys_out "encryptionKey");
  (* assets-only mode does NOT copy the extraneous file *)
  let out2 = Filename.concat root "out-assets" in
  let _ =
    Report.run
      {
        Report.game_dir = game;
        out_dir = out2;
        key;
        key_source = "test";
        dry_run = false;
        mirror = false;
        on_event = (fun _ -> ());
      }
  in
  let map_out2 =
    Filename.concat
      (Filename.concat (Filename.concat out2 "www") "data")
      "Map001.json"
  in
  check "assets-only skips extraneous json" (not (Sys.file_exists map_out2))

let () =
  test_crypto ();
  test_crypto_more ();
  test_mv ();
  test_mv_real_format ();
  test_xp_vx ();
  test_classify ();
  test_key_discovery ();
  test_vxace ();
  test_mz ();
  test_mz_multi ();
  test_log ();
  test_report ();
  test_mirror ();
  Printf.printf "\n===== %d checks, %d passed, %d failed =====\n" !total !passed
    (List.length !fails);
  List.iter (fun n -> Printf.printf "  FAIL %s\n" n) (List.rev !fails);
  if !fails = [] then (
    print_endline "  ALL PASS";
    exit 0)
  else exit 1
