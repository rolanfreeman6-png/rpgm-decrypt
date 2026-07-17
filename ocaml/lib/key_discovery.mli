(** MV/MZ encryption-key discovery without user input, plus wordlist validation.

    Uses yojson (System.json) and re (rpg_core.js literal scan); JavaScript is
    never evaluated. *)

type key_result =
  | Found of bytes * string
  | NotFound of string
      (** Outcome of discovery: [Found (key, source)] or [NotFound reason]. *)

val discover : string -> key_result
(** [discover game_dir] searches the standard locations for a 32-hex-char
    encryption key, covering both the classic MV layout (assets under [www/])
    and the newer MZ layout (assets directly in [game_dir]): js/System.json ->
    data/System.json -> js/rpg_core.js (each with and without the [www/]
    prefix), then a recursive [*.js] sweep of the whole game dir. *)

val discover_with_wordlist : string -> string array -> key_result
(** [discover_with_wordlist game_dir wordlist] validates each 32-hex candidate
    in [wordlist] against the first encrypted asset found under [game_dir].
    [NotFound] if the wordlist is empty or no encrypted asset exists. *)
