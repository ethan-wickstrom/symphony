(** Open provider set; packages keep settings and execution capabilities
    together. *)

module type CONFIG = sig
  type settings

  val kind : string

  val equal : settings -> settings -> bool
  (** Equivalence over scope, authentication and source provenance. Current
      normalization/eligibility policy belongs to requests, never settings. No
      credential bytes are observable. *)

  val secret_names : settings -> string list
  (** Fixed credential names plus every resolved $VAR source. The result is
      metadata only and does not grant access to the environment. *)

  val parse :
    env:Environment.t ->
    Config_value.t ->
    (settings * Environment.public, Tracker_error.t) result
  (** Pure validation/defaults/$VAR resolution. No filesystem, network, trust,
      clock or crypto initialization. Repeating the same parse yields equal
      successful settings. Return a public environment quarantining declared and
      resolved credentials, including selected literal credentials. Expected
      failures are values; defects propagate. *)

  val scope : settings -> Tracker_scope.t
end

module type S = sig
  include CONFIG

  type io

  val states :
    io ->
    settings ->
    policy:Tracker_read_policy.t ->
    string list ->
    (Issue_batch.t, Tracker_error.t) result
  (** Preserve provider order through every required page. Empty names perform
      zero requests. Deliver the whole checked batch or Error. Malformed
      required records may be omitted with a bounded operator-visible warning;
      optional metadata fallback alone is not malformed. Never overwrite
      duplicate IDs or identifiers. Warnings do not retain a global issue
      snapshot. *)

  val ids :
    io ->
    settings ->
    policy:Tracker_read_policy.t ->
    Issue_id.Set.t ->
    (Issue.t Issue_id.Map.t, Tracker_error.t) result
  (** Empty IDs perform zero requests. Return complete snapshots for the visible
      requested subset in scope, including non-active states. Missing/invisible
      IDs are absent; a malformed requested record fails the whole call. A
      record whose ID cannot be checked cannot safely be classified as
      unrelated.

      Both reads are atomic delivery across pages/chunks, not a provider
      database transaction. Page/byte/node/deadline bounds fail rather than
      truncate. Cancellation and unexpected defects preserve identity/backtrace;
      expected transport/provider failures return the Section 11.4 category. *)
end
