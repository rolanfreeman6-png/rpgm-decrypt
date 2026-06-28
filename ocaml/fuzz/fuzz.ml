(* Coverage-guided fuzz target for the untrusted-input parsers.
   Two modes:
     * `fuzz <file>`  — AFL single-shot: read the file, run every parser once.
       The parsers must return Result / never throw; an escaping exception
       propagates and is recorded by afl-fuzz as a crash (run with
       AFL_CRASH_EXITCODE=2 since an uncaught OCaml exception exits 2).
     * `fuzz`         — local in-process random/mutation loop for FUZZ_SECONDS
       (default 30) seconds, for a quick standalone robustness check without
       afl-fuzz. Prints iters + crash count. *)

open Rpgm

let key16 = Bytes.init 16 (fun i -> Char.chr ((i * 7) + 1))
let tmp_pak = Filename.concat (Filename.get_temp_dir_name ()) "rpgm_fuzz.pak"

(* Run every Result-returning target on one input. Exceptions are bugs. *)
let run_targets (data : bytes) (path : string) : unit =
  ignore (Xp.parse data);
  ignore (Vx.parse data);
  ignore (Vxace.parse data);
  ignore (Rgssad_core.parse 0x01 Rgssad_core.NameLenZero data);
  ignore (Rgssad_core.parse 0x02 Rgssad_core.SizeAndNameZero data);
  ignore (Mv.decrypt key16 data);
  ignore (Vxace_key.decode_payload data 0x12345);
  ignore (Vxace_key.decode_filename data 0x12345);
  ignore (Crypto.xor_transform key16 data);
  match Mz.open_pak path with
  | Ok z ->
      ignore (Mz.decrypt_all key16 z);
      (try Zip.close_in z with _ -> ())
  | Error _ -> ()

(* ---- seed corpus + mutation for local mode --------------------------- *)
let u32le b pos v =
  Bytes.set b pos (Char.chr (v land 0xFF));
  Bytes.set b (pos + 1) (Char.chr ((v lsr 8) land 0xFF));
  Bytes.set b (pos + 2) (Char.chr ((v lsr 16) land 0xFF));
  Bytes.set b (pos + 3) (Char.chr ((v lsr 24) land 0xFF))

let build_rgssad ver =
  let name = "Graphics/Hero.png" in
  let nlen = String.length name in
  let enc = Bytes.init nlen (fun i ->
      Char.chr (Char.code name.[i]
                lxor Char.code (Bytes.get Crypto.magic_rgssad_prefix (i mod 7)))) in
  let pos_payload = 8 + 12 + nlen + 12 in
  let buf = Bytes.make (pos_payload + 16) '\000' in
  Bytes.blit Crypto.magic_rgssad_prefix 0 buf 0 7;
  Bytes.set buf 7 (Char.chr ver);
  u32le buf 8 16; u32le buf 12 pos_payload; u32le buf 16 nlen;
  Bytes.blit enc 0 buf 20 nlen;
  buf

let mv_seed =
  Crypto.xor_transform key16 (Bytes.of_string "\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR")

let mz_seed =
  let z = Zip.open_out tmp_pak in
  Zip.add_entry (Bytes.to_string (Crypto.xor_transform key16 (Bytes.make 16 'A'))) z "www/img/a.png";
  Zip.close_out z;
  Io.read_file tmp_pak

let vxace_seed =
  let b = Bytes.make 92 '\000' in
  Bytes.blit Crypto.magic_rgssad_prefix 0 b 0 7;
  Bytes.set b 7 '\x03';
  for i = 12 to 91 do Bytes.set b i (Char.chr ((i * 13) land 0xFF)) done;
  b

let seeds = [| build_rgssad 0x01; build_rgssad 0x02; vxace_seed; mv_seed; mz_seed |]

let mutate rnd =
  if Random.State.int rnd 10 < 3 then
    Bytes.init (Random.State.int rnd 1024) (fun _ -> Char.chr (Random.State.int rnd 256))
  else begin
    let b = Bytes.copy seeds.(Random.State.int rnd (Array.length seeds)) in
    (match Random.State.int rnd 3 with
     | 0 ->
         for _ = 1 to 1 + Random.State.int rnd 30 do
           if Bytes.length b > 0 then
             Bytes.set b (Random.State.int rnd (Bytes.length b)) (Char.chr (Random.State.int rnd 256))
         done;
         b
     | 1 -> if Bytes.length b = 0 then b else Bytes.sub b 0 (Random.State.int rnd (Bytes.length b))
     | _ ->
         if Bytes.length b >= 4 then
           u32le b (Random.State.int rnd (Bytes.length b - 3)) 0xFFFFFFFA;
         b)
  end

let () =
  if Array.length Sys.argv >= 2 then begin
    (* AFL single-shot *)
    let path = Sys.argv.(1) in
    let data = try Io.read_file path with _ -> Bytes.create 0 in
    run_targets data path
  end
  else begin
    let secs =
      match Sys.getenv_opt "FUZZ_SECONDS" with
      | Some s -> (try float_of_string s with _ -> 30.0)
      | None -> 30.0
    in
    let rnd = Random.State.make [| 1337 |] in
    let started = Unix.gettimeofday () in
    let iters = ref 0 and crashes = ref 0 in
    while Unix.gettimeofday () -. started < secs do
      incr iters;
      let data = mutate rnd in
      (try
         Io.write_file tmp_pak data;
         run_targets data tmp_pak
       with e ->
         incr crashes;
         Printf.eprintf "CRASH: %s\n" (Printexc.to_string e))
    done;
    Printf.printf "in-process fuzz: %d iters, %d crashes in %.0fs\n" !iters !crashes secs;
    exit (if !crashes = 0 then 0 else 1)
  end
