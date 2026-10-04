(** Immutable, bounded JSONL framing for the selected stdio profile. *)

type t

type error =
  | Oversized of Diagnostic.t
  | Invalid_json of Diagnostic.t
  | Truncated of Diagnostic.t

type next = Open of t | Failed of error
type batch = { frames : Json.t list; next : next }

val max_bytes : int
(** Maximum bytes before a newline, including any trailing carriage return. The
    profile deliberately uses the checked JSON boundary's 1 MiB ceiling. *)

val empty : t

val feed : t -> string -> batch
(** Partition invariance preserves the accepted prefix, order and error
    category. An error returns preceding frames before rejecting the remaining
    input. Residual storage is bounded; each byte is copied logarithmically even
    when reads contain one byte. Callers supply bounded chunks and consume
    batches. States are persistent: feeding one state never changes another
    branch. *)

val finish : t -> (unit, error) result
(** Empty residual succeeds. EOF with any residual is Truncated. *)
