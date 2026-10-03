(** Whole-input oracle: split lines first, then use the checked JSON boundary.
    No production framer or incremental storage representation is used. *)

type failure = Oversized | Invalid_json | Truncated
type observation = { frames : Json.t list; failure : failure option }

val observe : max_bytes:int -> string -> observation
(** A rejected line preserves every earlier frame and ignores later lines. The
    size ceiling includes CR but excludes LF. Any remaining bytes at EOF are
    truncated, even when they form valid JSON without a newline. *)
