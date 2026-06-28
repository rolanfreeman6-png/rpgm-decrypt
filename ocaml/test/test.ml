(* In-process test runner for the OCaml port — mirrors the key F# tests so we
   can confirm behavioural parity. *)

open Rpgm

let total = ref 0
let passed = ref 0
let fails : string list ref = ref []

let check name cond =
  incr total;
  if cond then incr passed else fails := name :: !fails

let check_bytes name a b = check name (Bytes.equal a b)

let bytes_of_hex h = (* even-length hex -> bytes *)
  let n = String.length h / 2 in
  Bytes.init n (fun i ->
      let hx c = Crypto.hex_nibble (Char.lowercase_ascii c) in
      Char.chr ((hx h.[2 * i] lsl 4) lor hx h.[(2 * i) + 1]))

let raises f = try ignore (f ()); false with _ -> true

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
  check_bytes "xor involution" orig (Crypto.xor_transform key (Crypto.xor_transform key orig));
  check "looksLikePlaintext png" (Crypto.looks_like_plaintext (bytes_of_hex "89504E470D0A1A0A"));
  check "looksLikePlaintext ogg" (Crypto.looks_like_plaintext (Bytes.of_string "OggSxxxx"));
  check "looksLikePlaintext jpg" (Crypto.looks_like_plaintext (Bytes.of_string "\xff\xd8\xff\xe0"));
  check "looksLikePlaintext rejects RPGMV" (not (Crypto.looks_like_plaintext (Bytes.of_string "RPGMV3123456789012")));
  check "decodeHexKey rejects short" (raises (fun () -> Crypto.decode_hex_key "abcd"));
  check "decodeHexKey rejects non-hex" (raises (fun () -> Crypto.decode_hex_key "zz23456789abcdef0123456789abcdef"));
  check "xorTransform rejects empty key" (raises (fun () -> Crypto.xor_transform (Bytes.create 0) (Bytes.of_string "ab")))

(* ---- Mv -------------------------------------------------------------- *)
let test_mv () =
  let key = bytes_of_hex "123456789ABCDEF01122334455667788" in
  let png = bytes_of_hex "89504E470D0A1A0A0000000D49484452" in
  (match Mv.decrypt key png with
   | Mv.Plaintext (k, b) -> check "mv plaintext kind png" (k = "png"); check_bytes "mv plaintext bytes" png b
   | _ -> check "mv plaintext outcome" false);
  let cipher = Crypto.xor_transform key png in
  check "mv cipher not plaintext" (not (Crypto.looks_like_plaintext cipher));
  (match Mv.decrypt key cipher with
   | Mv.Decrypted (k, b) -> check "mv decrypted kind png" (k = "png"); check_bytes "mv decrypted bytes" png b
   | _ -> check "mv decrypted outcome" false);
  (match Mv.decrypt (Bytes.make 16 '\000') cipher with
   | Mv.Unsure _ -> check "mv wrong key -> Unsure" true
   | _ -> check "mv wrong key -> Unsure" false)

(* ---- XP / VX (shared Rgssad_core) ------------------------------------ *)
let build_rgssad ver =
  let name = "Graphics/Hero.png" in
  let nlen = String.length name in
  let enc =
    Bytes.init nlen (fun i ->
        Char.chr (Char.code name.[i]
                  lxor Char.code (Bytes.get Crypto.magic_rgssad_prefix (i mod 7))))
  in
  let payload = Bytes.init 8 (fun i -> Char.chr i) in
  let psize = Bytes.length payload in
  let pos_payload = 8 + 12 + nlen + 12 in
  let total = pos_payload + psize in
  let buf = Bytes.make total '\000' in
  Bytes.blit Crypto.magic_rgssad_prefix 0 buf 0 7;
  Bytes.set buf 7 (Char.chr ver);
  set_u32le buf 8 psize;            (* size *)
  set_u32le buf 12 pos_payload;     (* offset *)
  set_u32le buf 16 nlen;            (* name_len *)
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
  check "xp bad magic" (match Xp.parse (Bytes.of_string "\xff\xff\xff\xff\xff\xff\xff\x01") with Error Rgssad_core.BadMagic -> true | _ -> false);
  check "xp bad version" (match Xp.parse (Bytes.of_string "\x52\x47\x53\x53\x41\x44\x00\x02") with Error (Rgssad_core.BadVersion 2) -> true | _ -> false);
  (* VX v2 *)
  let buf2, name2, _, _ = build_rgssad 0x02 in
  (match Vx.parse buf2 with
   | Ok (entries, _) -> check "vx 1 entry" (List.length entries = 1); check "vx name" ((List.hd entries).Rgssad_core.name = name2)
   | Error _ -> check "vx parse ok" false);
  check "vx bad version" (match Vx.parse (Bytes.of_string "\x52\x47\x53\x53\x41\x44\x00\x01") with Error (Rgssad_core.BadVersion 1) -> true | _ -> false);
  (* I-1 regression: high-bit name_len must yield Truncated, never crash.
     20-byte buffer: header(8) + size(nonzero,4) + offset(4) + name_len(4). *)
  let bad = Bytes.make 20 '\000' in
  Bytes.blit Crypto.magic_rgssad_prefix 0 bad 0 7;
  Bytes.set bad 7 '\x02';
  set_u32le bad 8 0x10;          (* size nonzero -> not the sentinel *)
  set_u32le bad 16 0xFFFFFFFA;   (* name_len high-bit *)
  check "vx high-bit name_len -> Truncated" (match Vx.parse bad with Error Rgssad_core.Truncated -> true | _ -> false)

(* ---- VX Ace ---------------------------------------------------------- *)
let test_vxace () =
  let master = 3 in (* seed 0 -> 0*9+3 *)
  let enc_u32 d = d lxor master in
  let name = "Hero.png" in
  let nlen = String.length name in
  let plain_payload = Bytes.init 16 (fun i -> Char.chr (i + 1)) in
  let cipher_payload = Vxace_key.decode_payload plain_payload 0 in (* entry_key=0; XOR keystream is involutive *)
  let psize = Bytes.length cipher_payload in
  let pos_payload = 12 + 16 + nlen + 16 in
  let total = pos_payload + psize in
  let buf = Bytes.make total '\000' in
  Bytes.blit Crypto.magic_rgssad_prefix 0 buf 0 7;
  Bytes.set buf 7 '\x03';
  (* seed = 0 at 8..11 already *)
  set_u32le buf 12 (enc_u32 pos_payload);  (* offset *)
  set_u32le buf 16 (enc_u32 psize);        (* size *)
  set_u32le buf 20 (enc_u32 0);            (* entry key *)
  set_u32le buf 24 (enc_u32 nlen);         (* name_len *)
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
       check_bytes "vxace payload roundtrip" plain_payload (Vxace.decrypt_payload e sliced)
   | Error _ -> check "vxace parse ok" false);
  check "vxace bad version" (match Vxace.parse (Bytes.of_string "\x52\x47\x53\x53\x41\x44\x00\x01\x00\x00\x00\x00") with Error (Vxace.BadVersion 1) -> true | _ -> false);
  (* master-key formula *)
  check "deriveMasterKey seed0" (Vxace_key.derive_master_key (Bytes.make 4 '\000') 0 = 3)

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
   | Ok zf ->
       (match Mz.decrypt_all key zf with
        | Ok [ e ] ->
            check "mz entry name" (e.Mz.entry_name = "www/img/test.png");
            check "mz kind png" (e.Mz.plaintext_kind = "png");
            check_bytes "mz bytes" png e.Mz.bytes
        | _ -> check "mz decryptAll 1 entry" false);
       (try Zip.close_in zf with _ -> ())
   | Error _ -> check "mz openPak" false);
  check "mz rejects non-zip" (match Mz.open_pak Sys.argv.(0) with Error Mz.NotAZipFile -> true | Ok _ -> (check "" true; false) | Error _ -> false);
  Sys.remove pak

(* ---- safe_join + end-to-end Report.run ------------------------------- *)
let test_report () =
  (* safe_join *)
  check "safeJoin nested allowed" (Report.safe_join "/tmp/out" "www/img/a.png" <> None);
  check "safeJoin traversal blocked" (Report.safe_join "/tmp/out" "../../evil.txt" = None);
  (* MV end-to-end round-trip *)
  let root = Filename.temp_dir "rpgm" "e2e" in
  let game = Filename.concat root "game" in
  Report.mkdir_p (Filename.concat (Filename.concat game "www") "js");
  Report.mkdir_p (Filename.concat (Filename.concat game "www") "img");
  Io.write_file
    (Filename.concat (Filename.concat (Filename.concat game "www") "js") "System.json")
    (Bytes.of_string {|{ "encryptionKey": "deadbeef00112233445566778899aabb" }|});
  let key = Crypto.decode_hex_key "deadbeef00112233445566778899aabb" in
  let png = bytes_of_hex "89504E470D0A1A0A0000000D49484452AABBCC" in
  Io.write_file
    (Filename.concat (Filename.concat (Filename.concat game "www") "img") "Hero.png_")
    (Crypto.xor_transform key png);
  let out = Filename.concat root "out" in
  let summary =
    Report.run
      { Report.game_dir = game; out_dir = out; key; key_source = "test";
        dry_run = false; on_event = (fun _ -> ()) }
  in
  check "e2e failed=0" (summary.Types.failed_count = 0);
  let hero = Filename.concat (Filename.concat (Filename.concat out "www") "img") "Hero.png" in
  check "e2e Hero.png exists" (Sys.file_exists hero);
  if Sys.file_exists hero then check_bytes "e2e roundtrip" png (Io.read_file hero);
  (* MZ Zip-Slip blocked end-to-end *)
  let game2 = Filename.concat root "game2" in
  Report.mkdir_p game2;
  let cipher = Crypto.xor_transform key (bytes_of_hex "89504E470D0A1A0A0000000D49484452") in
  let pak = Filename.concat game2 "packed.pak" in
  let z = Zip.open_out pak in
  Zip.add_entry (Bytes.to_string cipher) z "../evil.png";
  Zip.close_out z;
  let out2 = Filename.concat root "out2" in
  let s2 =
    Report.run
      { Report.game_dir = game2; out_dir = out2; key; key_source = "test";
        dry_run = false; on_event = (fun _ -> ()) }
  in
  check "zipslip counted failed" (s2.Types.failed_count >= 1);
  check "zipslip nothing escaped" (not (Sys.file_exists (Filename.concat root "evil.png")))

let () =
  test_crypto ();
  test_mv ();
  test_xp_vx ();
  test_vxace ();
  test_mz ();
  test_report ();
  Printf.printf "\n===== %d checks, %d passed, %d failed =====\n" !total !passed (List.length !fails);
  List.iter (fun n -> Printf.printf "  FAIL %s\n" n) (List.rev !fails);
  if !fails = [] then (print_endline "  ALL PASS"; exit 0) else exit 1
