(** Declarative hook policy oracle. Calls are driver-boundary observations, not
    process launches. No production manager function computes an expectation. *)

type presence = Absent | Present
type operation = Attempt | Cleanup

type normal_stage =
  | Acquire
  | Lookup
  | After_create
  | Before_run
  | Path
  | Callback

type stage = Normal of normal_stage | After_run | Before_remove | Remove
type failure = Rejected | Timed_out
type response = Proceed | Fail of failure

type scenario = {
  initial : presence;
  operation : operation;
  respond : stage -> response;
  cancel_at : normal_stage option;
}

type event =
  | Call of stage
  | Release
  | Enter_cleanup
  | Leave_cleanup
  | Report of stage * failure

type outcome =
  | Returned
  | Errored of stage * failure
  | Cancelled of normal_stage

type observation = {
  presence : presence;
  outcome : outcome;
  trace : event list;
}

val run : scenario -> observation
(** Interpret a successful prefix followed by its first fault, then the declared
    cleanup suffix. Created preparation failure removes; reused preparation
    failure and all callback outcomes preserve. Expected cleanup errors add
    reports without replacing the primary outcome. Every acquired lease has one
    release, including cancellation. Successful cleanup followed by another
    cleanup preserves the absent filesystem projection. *)

val equal : observation -> observation -> bool
(** Equality observes final presence, primary outcome, ordered driver calls,
    reports, cleanup scopes, and release multiplicity. *)

val show : observation -> string
(** Printable counterexample; includes every observation compared by [equal]. *)
