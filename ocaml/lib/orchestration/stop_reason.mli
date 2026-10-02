(** Closed owner decisions, distinct from the agent's reported outcome. *)

type t =
  | Reconcile_terminal
  | Reconcile_inactive
  | Reconcile_missing
  | Reconcile_unroutable
  | Scope_changed
  | Stall_detected
  | Shutdown_requested
