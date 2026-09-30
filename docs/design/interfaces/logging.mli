(** Section 3.1 component. No raw credentials/environment/protocol object printer. *)

module type PURE = sig
  type entry
  type level = Debug | Info | Warning | Error
  type context =
    | Service
    | Issue of { id : Issue_id.t; identifier : Issue_identifier.t }
    | Session of { id : Issue_id.t; identifier : Issue_identifier.t; session : Session_id.t }
  val event : level -> context -> name:string -> fields:(string * string) list -> entry
  (** Redacted domain values only. Entries are immutable; ordered entry lists use
      Stdlib list concatenation's free monoid, with [] identity. *)

  val diagnostic : context -> Diagnostic.t -> entry
end

module type S = sig
  module Contract : PURE
  type t
  val emit : t -> Contract.entry -> (unit, Diagnostic.t) result
  (** key=value stderr encoding: bounded, escaped, deterministic. Sink failure
      never changes orchestration decisions or prevents teardown. *)

end
