(** Orchestrator: walk -> classify -> decrypt -> write a mirror tree, building a
    run summary. Port of the F# [Report] module.

    Includes the Zip-Slip path-containment check ({!safe_join}) and the MZ
    [rename_by_kind] argument-order fix. *)

type config = {
  game_dir : string;
  out_dir : string;
  key : bytes;
  key_source : string;
  dry_run : bool;
  on_event : Log.event -> unit;
}
(** Run configuration. [on_event] receives every log event; [dry_run] skips all
    writes. *)

val mkdir_p : string -> unit
(** [mkdir_p dir] creates [dir] and parents (like [mkdir -p]); no-op if it
    exists. *)

val safe_join : string -> string -> string option
(** [safe_join out_dir rel] resolves [rel] under [out_dir], returning
    [Some abs_path] only if the result stays inside [out_dir] (no absolute path,
    no [..] traversal — the Zip-Slip defence), or [None] if [rel] escapes. *)

val run : config -> Types.run_summary
(** [run cfg] walks [cfg.game_dir], decrypts/copies each detected file into
    [cfg.out_dir] (unless [cfg.dry_run]), and returns the run summary. *)
