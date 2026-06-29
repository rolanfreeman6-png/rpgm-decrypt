(* Property-based tests (QCheck2) for the rpgm-decrypt OCaml port.

   These complement the 72 behavioural checks in [test/test.ml] with
   randomized invariant checks on the pure core: XOR involution, hex-key
   round-trip, VX-Ace key derivation, parser totality (never throws on arbitrary
   bytes), the Zip-Slip containment of [Report.safe_join], and the totality of
   [Dispatch.choose_output_extension].

   Fixed RNG seed (42) for reproducibility. Run via `dune exec test/prop/prop.exe`.
   Exit code 0 = all properties hold, 1 = some property failed. *)

open Rpgm
module G = QCheck2.Gen

(* ---- helpers --------------------------------------------------------- *)

let set_u32le b pos v =
  Bytes.set b pos (Char.chr (v land 0xFF));
  Bytes.set b (pos + 1) (Char.chr ((v lsr 8) land 0xFF));
  Bytes.set b (pos + 2) (Char.chr ((v lsr 16) land 0xFF));
  Bytes.set b (pos + 3) (Char.chr ((v lsr 24) land 0xFF))

(* Lowercase hex encoding of [b] — the inverse of [Crypto.decode_hex_key] on
   valid 32-char input. *)
let hex_of_bytes b =
  let n = Bytes.length b in
  let buf = Bytes.create (n * 2) in
  for i = 0 to n - 1 do
    let v = Char.code (Bytes.get b i) in
    let digit x =
      Char.chr (if x < 10 then Char.code '0' + x else Char.code 'a' + (x - 10))
    in
    Bytes.set buf (2 * i) (digit (v lsr 4));
    Bytes.set buf ((2 * i) + 1) (digit (v land 0xF))
  done;
  Bytes.to_string buf

let key16 = Bytes.init 16 (fun i -> Char.chr ((i * 7) + 1))

let never_throws f x =
  try
    ignore (f x);
    true
  with _ -> false

(* ---- arbitraries ----------------------------------------------------- *)

let arb_nonempty_bytes max = G.bytes_size (G.int_range 1 max)
let arb_bytes_upto max = G.bytes_size (G.int_range 0 max)
let arb_exact_bytes n = G.bytes_size (G.return n)
let arb_key_data = G.pair (arb_nonempty_bytes 64) (arb_bytes_upto 256)

(* ---- properties ------------------------------------------------------ *)

let p_xor_involution =
  QCheck2.Test.make ~name:"xor_transform is involutive" ~count:1000 arb_key_data
    (fun (key, data) ->
      Bytes.equal
        (Crypto.xor_transform key (Crypto.xor_transform key data))
        data)

let p_xor_length =
  QCheck2.Test.make ~name:"xor_transform preserves length" ~count:1000
    arb_key_data (fun (key, data) ->
      Bytes.length (Crypto.xor_transform key data) = Bytes.length data)

let p_hex_roundtrip =
  QCheck2.Test.make ~name:"decode_hex_key inverts hex_of_bytes" ~count:1000
    (arb_exact_bytes 16) (fun b ->
      Bytes.equal (Crypto.decode_hex_key (hex_of_bytes b)) b)

let p_derive_master_key =
  QCheck2.Test.make
    ~name:"derive_master_key = u32 (seed*9+3) over all 32-bit seeds" ~count:1000
    (G.int_range 0 ((1 lsl 32) - 1))
    (fun seed ->
      let b = Bytes.make 4 '\000' in
      set_u32le b 0 seed;
      Vxace_key.derive_master_key b 0 = Vxace_key.u32 ((seed * 9) + 3))

let p_decode_payload_involution =
  QCheck2.Test.make ~name:"decode_payload is involutive at a fixed entry key"
    ~count:1000 (arb_bytes_upto 256) (fun cipher ->
      Bytes.equal
        (Vxace_key.decode_payload
           (Vxace_key.decode_payload cipher 0x12345)
           0x12345)
        cipher)

(* The archive parsers must return a Result for ANY input — an out-of-bounds
   access or escaping exception on adversarial bytes is a bug. *)
let p_parsers_total =
  QCheck2.Test.make ~name:"parsers never throw on arbitrary bytes" ~count:500
    (arb_bytes_upto 4096) (fun b ->
      never_throws Xp.parse b && never_throws Vx.parse b
      && never_throws Vxace.parse b
      && never_throws (Rgssad_core.parse 0x01 Rgssad_core.NameLenZero) b
      && never_throws (Rgssad_core.parse 0x02 Rgssad_core.SizeAndNameZero) b)

let p_mv_decrypt_total =
  QCheck2.Test.make ~name:"Mv.decrypt never throws on arbitrary bytes"
    ~count:500 (arb_bytes_upto 4096) (fun b ->
      never_throws (Mv.decrypt key16) b)

let p_vxace_key_total =
  QCheck2.Test.make ~name:"Vxace_key.decode_payload/decode_filename never throw"
    ~count:500 (arb_bytes_upto 4096) (fun b ->
      never_throws (Vxace_key.decode_payload b) 0x12345
      && never_throws (Vxace_key.decode_filename b) 0x12345)

(* Zip-Slip: a path of N ".." segments always escapes the root -> None. *)
let p_safe_join_blocks_escape =
  QCheck2.Test.make ~name:"safe_join blocks '..' escape and absolute paths"
    ~count:100 (G.int_range 1 10) (fun n ->
      let dots = String.concat "/" (List.init n (fun _ -> "..")) in
      Report.safe_join "/tmp/out" dots = None
      && Report.safe_join "/tmp/out" "/etc/passwd" = None
      && Report.safe_join "/tmp/out" "../evil" = None)

(* Legitimate nested relative paths are allowed (not over-blocked). *)
let p_safe_join_allows_nested =
  QCheck2.Test.make ~name:"safe_join allows clean nested relative" ~count:1000
    (G.list (G.oneof_list [ "a"; "b"; "c"; "img"; "x"; "www" ]))
    (fun segs -> Report.safe_join "/tmp/out" (String.concat "/" segs) <> None)

(* Whatever the input, if safe_join returns Some, the normalized result contains
   no ".." component (it is fully resolved) and is either the root itself or a
   proper descendant of it. The no-".." check is independent of safe_join's own
   prefix test (it guards [normalize]); the prefix check is a regression guard. *)
let p_safe_join_containment =
  QCheck2.Test.make
    ~name:"safe_join result is contained (no '..' and under root prefix)"
    ~count:1000
    (G.list
       (G.oneof_list
          [ ".."; "."; ""; "a"; "b"; "/"; "../x"; "/abs"; "img"; "www" ]))
    (fun parts ->
      let rel = String.concat "/" parts in
      match Report.safe_join "/tmp/out" rel with
      | None -> true
      | Some full ->
          let comps = String.split_on_char '/' full in
          let no_parent = not (List.mem ".." comps) in
          let root = "/tmp/out" in
          let rootsep = root ^ "/" in
          let under_root =
            full = root
            || String.length full >= String.length rootsep
               && String.sub full 0 (String.length rootsep) = rootsep
          in
          no_parent && under_root)

let p_choose_ext_total =
  QCheck2.Test.make
    ~name:"choose_output_extension is total and yields a valid extension"
    ~count:1000
    (G.pair
       (G.oneof_list [ ".png_"; ".ogg_"; ".m4a_"; ".xyz"; ".rpgmvp"; "" ])
       (G.oneof_list
          [ "png"; "ogg"; "m4a"; "webp"; "jpg"; "bin"; "unknown"; "" ]))
    (fun (ext, kind) ->
      let r = Dispatch.choose_output_extension ext kind in
      r <> "" && List.mem r [ ".png"; ".ogg"; ".m4a"; ".webp"; ".jpg"; ".bin" ])

let tests =
  [
    p_xor_involution;
    p_xor_length;
    p_hex_roundtrip;
    p_derive_master_key;
    p_decode_payload_involution;
    p_parsers_total;
    p_mv_decrypt_total;
    p_vxace_key_total;
    p_safe_join_blocks_escape;
    p_safe_join_allows_nested;
    p_safe_join_containment;
    p_choose_ext_total;
  ]

let () =
  QCheck_base_runner.set_seed 42;
  exit (QCheck_base_runner.run_tests tests)
