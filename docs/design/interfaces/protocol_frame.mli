(** Pure bounded newline-delimited JSON framing. Not an HTTP Content-Length protocol. *)

type t
type error = Oversized of Diagnostic.t | Invalid_json of Diagnostic.t | Truncated of Diagnostic.t
val empty : t
type next = Open of t | Failed of error
type batch = { frames : Json.t list; next : next }
val feed : t -> string -> batch
(** Chunk invariance: feeding [a] then [b] equals feeding [a^b], including error
    category and accepted prefix, while preserving frame order. An error retains
    preceding frames in its batch, so transport chunking cannot discard that prefix.
    Newline splits frames, not reads. Retained bytes/frame sizes are bounded; malformed
    input never escapes. Caller reads bounded chunks and consumes each batch promptly. *)

val finish : t -> (unit, error) result
(** Empty residual succeeds; an incomplete residual is Truncated. *)
