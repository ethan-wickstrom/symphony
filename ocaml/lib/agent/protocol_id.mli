(** Codex 0.159.2 RequestId: string or signed int64, distinct from owner IDs. *)

type t
type view = String of string | Integer of int64

type error =
  | Invalid_type
  | Invalid_integer
  | Integer_range
  | String_limit
  | Invalid_utf8
  | Invalid_json

val of_string : string -> (t, error) result
(** Empty strings are schema-valid. IDs are limited to 1024 UTF-8 bytes. *)

val of_int64 : int64 -> t
val view : t -> view
val equal : t -> t -> bool

val compare : t -> t -> int
(** Equality and ordering preserve the variant: ["7"] and [7] differ. *)

val decode : Json.t -> (t, error) result
(** Accept only integer JSON lexemes in the full signed-64-bit range. Decimal
    points and exponents are rejected, matching Rust's integer wire shape. *)

val encode : t -> (Json.t, error) result
(** Decoding the encoded value preserves the exact variant and value. Error
    categories contain no inbound payload or credential bytes. *)
