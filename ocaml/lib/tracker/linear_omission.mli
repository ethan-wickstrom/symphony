(** Bounded diagnostic projection of one malformed Linear state record. *)

type field = Id | Identifier | Title | State

type reason =
  | Missing_field of field
  | Wrong_type of field
  | Invalid_record
  | Record_rejected

type identity
type t

val make : reason -> Json.t -> t
(** Pure provider-boundary constructor. Check only id/identifier strings for
    nonempty valid UTF-8 identity, then retain their bounded projection. Do not
    retain the JSON value, description, native_ref, raw Issue.parse error or any
    other provider text. The given closed reason is stored unchanged.

    Checked identity text at most 128 bytes retains its escaped exact text;
    larger values use SHA256 of the exact checked bytes. Invalid/missing
    identity projects to unknown. Digests are diagnostic provenance, never
    Issue_id or lookup authority. Construction is total over checked Json.t
    values. *)

val identity : t -> identity

val identity_text : identity -> string
(** The escaped checked projection is at most 2048 bytes. Repeated observation
    agrees. The parser is the only constructor; callers cannot forge identity.
*)

val reason : t -> reason
(** [reason (make r json) = r]. *)

val diagnostic : t -> Diagnostic.t
(** Fixed messages/remedies name the rejected key and checked identity.
    Rendering is at most 4096 bytes. Record_rejected names
    id/identifier/title/state without inspecting or storing Issue.parse's
    free-form error. Derived on observation; repeated make/observation agrees
    and no global warning list is retained. *)
