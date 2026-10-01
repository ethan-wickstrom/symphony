(** Executable wire examples whose meaning is an ordinary list of body chunks.
    This model does not call H1 or reproduce its parser. *)

type framing = Fixed | Chunked | Until_eof

val body : string list -> string
(** List concatenation: [body [] = ""] and [body (xs @ ys) = body xs ^ body ys].
*)

val wire : status:int -> framing -> string list -> string
(** Encode one valid response with the model's concatenated body. Empty chunks
    carry no bytes and do not terminate a chunked message. *)

val split : width:int -> string -> string list option
(** Nonpositive widths return [None]. For positive widths,
    [split ~width s = Some xs] implies [body xs = s]; the list preserves order
    and each member has at most [width] bytes. *)
