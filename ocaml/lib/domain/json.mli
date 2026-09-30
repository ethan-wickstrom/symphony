(** Checked, JSON-safe boundary value. The implementation wraps a library
    parser; it rejects duplicate object keys and nonstandard numeric values. *)

type t

type view =
  | Null
  | Bool of bool
  | Number of string
  | String of string
  | Array of t list
  | Object of (string * t) list

val parse : string -> (t, string) result

val encode : t -> string
(** [parse (encode j) = Ok j], under semantic JSON equality. *)

val view : t -> view

val equal : t -> t -> bool
(** Semantic equality: object order is irrelevant; exact decimal values compare
    without expanding exponents. Equivalence relation. Arrays preserve order. *)

val of_view : view -> (t, string) result
(** Validates numeric lexemes and unique object keys; never builds invalid JSON.
    Charges encoded bytes and nodes incrementally before serialization,
    including repeated checked children. Oversized composition is rejected
    without allocating its encoded output. *)
