(** Explicit trusted host snapshot; no process-global getenv operation. *)

type t
type public
type child

module Secret : sig
  type t

  val make : string -> t option
  (** Exact nonempty bytes become an opaque quarantine value. No byte observer.
      [make "" = None]. *)

  val equal : t -> t -> bool
  (** Equivalence over exact bytes. *)

  val redacted : t -> string
  (** Constant for every secret. *)
end

module Quarantine : sig
  type t

  val check : t -> string -> (string, string) result
  (** Reject exact credential bytes; success preserves the input. Idempotent. *)

  val check_json : t -> Json.t -> (Json.t, string) result
  (** Guard every string leaf, object key and numeric value, and every subtree
      under [Json.equal]. Success returns the same checked value. *)

  val equal : t -> t -> bool
  (** Equality of immutable denied-name and exact credential-value membership,
      independent of order and duplicates. Equal rules yield equal guard
      outcomes. No credential or environment observers. *)
end

val of_bindings :
  temp_dir:Absolute_path.t -> (string * string) list -> (t, string) result
(** Rejects duplicate/invalid names and NUL-containing or invalid UTF-8 values.
*)

val lookup : t -> string -> string option
(** Privileged credential/bootstrap resolution only. *)

val temp_dir : t -> Absolute_path.t
(** Explicit host capability; settings never inspect ambient temporary-directory
    state. *)

val public : t -> deny:string list -> secrets:Secret.t list -> public
(** Deny named sources, their nonempty resolved values, equal-value aliases and
    explicit credential literals. Restrictions are immutable and independent of
    input order or duplicate entries. Recognition exposes no secret bytes. *)

val quarantine : public -> Quarantine.t
(** Shares immutable rules; exposes no environment bindings. Deferred checked
    producers retain only this capability. *)

val lookup_public : public -> string -> (string option, string) result
(** A denied source/value or credential used as the requested name yields a
    fixed redacted error. A missing nonsecret name yields [Ok None]; a public
    value yields [Ok (Some value)]. *)

val check : public -> string -> (string, string) result
(** [check p v = Ok v] exactly when v is not quarantined. Guard literals and
    canonical conversion output. Successful checks are idempotent. *)

val check_json : public -> Json.t -> (Json.t, string) result
(** Complete recursive guard, including keys, string leaves, numeric aliases and
    semantically equivalent subtrees. Success returns the same input; checks are
    idempotent. Parsed recognition exposes no credential bytes. *)

val public_temp_dir : public -> (Absolute_path.t, string) result
(** Guard the canonical temporary path before exposing it to public settings. *)

val child : public -> allow:string list -> child
(** Names are a subset of the allowlist minus denied sources and value aliases.
    Duplicates/order have no effect. Credential bytes cannot enter a child via
    an allowed alias such as PATH. Never inherit by subtraction alone. *)

val bindings : child -> (string * string) list
(** Only the sanitized child environment is observable; no raw snapshot printer.
*)
