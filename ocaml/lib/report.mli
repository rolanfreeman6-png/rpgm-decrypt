(** Orchestrator: walk -> classify -> decrypt -> write a mirror tree, building a
    run summary.

    Includes the Zip-Slip path-containment check ({!safe_join}) and the MZ
    [rename_by_kind] argument-order fix. *)

(* Uninterpreted helpers (Gospel 0.3.1 has no String theory). [normalize]
    models path normalisation (resolving "."/".."); [string_prefix s p] holds
    when [s] starts with [p]; the safe_join spec states the Zip-Slip containment
    contract — any [Some] result is the normalised root or a descendant of it.
    The actual containment is verified by the QCheck property
    [p_safe_join_containment] and is the target of the cameleer/Why3 proof. *)
(*@ function normalize (p: string) : string *)
(*@ function string_concat (a b: string) : string *)
(*@ predicate string_prefix (s prefix: string) *)

type config = {
  game_dir : string;
  out_dir : string;
  key : bytes;
  key_source : string;
  dry_run : bool;
  mirror : bool;
  on_event : Log.event -> unit;
}
(** Run configuration. [on_event] receives every log event; [dry_run] skips all
    writes. When [mirror] is set, the whole game tree is cloned into [out_dir]
    first (preserving every non-asset file), the encrypted assets are decrypted
    in place, and each [System.json]'s [hasEncryptedImages]/[hasEncryptedAudio]
    flags are cleared so the copy is playable as-is. When [mirror] is [false]
    only the decrypted assets are written (assets-only mode). *)

val mkdir_p : string -> unit
(** [mkdir_p dir] creates [dir] and parents (like [mkdir -p]); no-op if it
    exists. *)

val safe_join : string -> string -> string option
(** [safe_join out_dir rel] resolves [rel] under [out_dir], returning
    [Some abs_path] only if the result stays inside [out_dir] (no absolute path,
    no [..] traversal — the Zip-Slip defence), or [None] if [rel] escapes. *)
(*@ r = safe_join out_dir rel
    ensures
      match r with
      | None -> true
      | Some full ->
          full = normalize out_dir
          || string_prefix full (string_concat (normalize out_dir) "/") *)

val run : config -> Types.run_summary
(** [run cfg] walks [cfg.game_dir], decrypts/copies each detected file into
    [cfg.out_dir] (unless [cfg.dry_run]), and returns the run summary. *)
