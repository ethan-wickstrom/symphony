(** Independent finite envelope and list-history models. No production Linear
    parser is called by this module. *)

type errors = No_errors | Ordinary_errors | Rate_errors | Invalid_errors
type data = Object_data | Missing_data | Other_data
type envelope = Invalid_json | Valid of errors * data
type response = Accepted | Rate | Status | Malformed

val response : status:int -> envelope -> response
(** HTTP 429 absorbs all envelopes. Other non-2xx statuses absorb envelopes,
    except a valid RATELIMITED error promotes HTTP 400. Within 2xx, GraphQL
    errors absorb data. Adding data cannot turn an error into Accepted. *)

type history

val start : history

val advance : history -> string -> history option
(** List membership is the oracle: new cursors append once, repeats reject. *)

val ordered : 'a list list -> 'a list
(** Page partition changes do not alter ordered concatenation. *)

type completeness = Complete | Incomplete

type blocker =
  | Other
  | Unknown
  | Blocks of { source : string; target : string; state : string option }

val dispatchable :
  id:string ->
  state:string ->
  terminal:string list ->
  completeness ->
  blocker list ->
  bool
(** Todo needs complete, non-self, matching-target terminal evidence. Other
    states ignore blocker evidence. Removing metadata cannot supply evidence. *)

val labels : string list -> string list
(** ASCII corpus model: trim/lowercase, discard blanks, deduplicate by list
    membership, then sort the unique set projection; idempotent. Labels have set
    semantics, unlike the ordered issue stream. Known Unicode mappings are
    checked separately at the shared text boundary. *)

type decimal

val decimal : mantissa:int -> scale:int -> exponent:int -> decimal option
(** Bounded rational corpus: |mantissa| <= 1,000,000, scale 0..6, exponent
    -25..25. Outside that corpus returns None rather than expanding huge powers.
*)

val lexeme : decimal -> string

val integer : decimal -> int option
(** Exact rational mantissa * 10^(exponent-scale), using Zarith division and
    remainder. No production canonicalizer, float or JSON parser is an oracle.
*)
