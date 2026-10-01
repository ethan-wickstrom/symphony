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

val encoded_bytes : t -> int
(** [encoded_bytes j = String.length (encode j)], without allocating the encoded
    output. Derived from the checked tree, never cached. Constructor bounds
    guarantee that the exact sum fits OCaml int. *)

val view : t -> view

val equal : t -> t -> bool
(** Semantic equality: object order is irrelevant; exact decimal values compare
    without expanding exponents. Equivalence relation. Arrays preserve order. *)

val to_int : t -> int option
(** Exact bounded integer projection of Number; never round through float or
    expand an unbounded exponent. Return Some n exactly for integral values
    representable by OCaml int. Equivalent JSON numbers have equal projections;
    [to_int (Number (string_of_int n)) = Some n] through [of_view]. *)

val of_view : view -> (t, string) result
(** Validates numeric lexemes and unique object keys; never builds invalid JSON.
    Charges encoded bytes and nodes incrementally before serialization,
    including repeated checked children. Oversized composition is rejected
    without allocating its encoded output. *)
