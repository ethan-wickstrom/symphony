(** Portable tracker reads. Provider choice is frozen inside each binding. *)

module type PURE = sig
  module Issue : Issue.S

  type binding

  type request =
    | States of {
        id : Request_id.t;
        binding : binding;
        policy : Tracker_read_policy.t;
        names : string list;
      }
    | Ids of {
        id : Request_id.t;
        binding : binding;
        policy : Tracker_read_policy.t;
        ids : Issue_id.Set.t;
      }

  type reply = (Issue.t Issue_id.Map.t, Tracker_error.t) result

  val scope : binding -> Tracker_scope.t

  val equal : binding -> binding -> bool
  (** Equivalence including settings and captured capability-context identity.
      Different registry entries compare unequal; one unchanged entry with equal
      settings compares equal. Secret changes are observable only as inequality.
  *)

  val secret_names : binding -> string list
end

module type CONFIG = sig
  module Contract : PURE with module Issue = Issue

  type t

  val configure :
    t ->
    env:Environment.t ->
    kind:Config_value.t ->
    provider:Config_value.t ->
    (Contract.binding * Environment.public, Tracker_error.t) result
  (** Pure adapter selection/settings construction. The returned binding
      captures that adapter entry's settings witness, settings and io, once. No
      request. Credential bootstrap precedes public routing/core configuration;
      the original selector is checked under the returned public capability. *)
end

module type S = sig
  include CONFIG

  val execute : Contract.request -> Contract.reply
  (** Execute with the request's original binding, including after registry or
      workflow replacement. States derives Issue_batch.by_id for the core. No
      current-registry parameter permits re-selection. Expected failures are
      atomic replies; cancellation/defects propagate. Owner-side request
      identity fencing remains mandatory. No generic writes or raw credential
      access. *)
end
