(** Checked single directory component; acquisition separately verifies
    ownership. *)

type t

val of_identifier : Issue_identifier.t -> (t, string) result
(** Let [r = Issue_identifier.text identifier]. Let [S] replace each byte
    outside ASCII [A-Za-z0-9._-] with [_], without trimming or Unicode decoding.
    Let [H(r)] be the lowercase hexadecimal first 16 bytes of SHA-256 over [r].

    The candidate is [S(r)] when [S(r) = r], otherwise [S(r) ^ "-" ^ H(r)].
    Accept exactly candidates other than [""], ["."], [".."] whose byte length
    is at most 255. Errors explain the rejected component; no truncation occurs.

    Laws:
    - [S(S(r)) = S(r)] and [length(S(r)) = length(r)].
    - Successful unchanged identifiers preserve every byte.
    - Repeated construction from the same identifier has the same result.
    - If [Ok k] is returned, reparsing [text k] as an [Issue_identifier.t] and
      constructing again returns [Ok k'] with [compare k k' = 0].

    This pure transformation does not establish injectivity, scope ownership,
    filesystem case identity, or physical containment. Acquisition checks those
    facts before creating or reusing a workspace. *)

val text : t -> string
(** [text k] is nonempty, is neither dot component, contains only allowed ASCII
    bytes, and has length at most 255. *)

val compare : t -> t -> int
(** Total byte order, agreeing with [String.compare (text a) (text b)].
    Reflexive, sign-antisymmetric, transitive, and total; zero iff texts agree.
*)
