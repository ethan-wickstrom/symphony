(** Closed owner decisions. Shared directly rather than copied into worker metadata. *)

type t =
  | Reconcile_terminal
  | Reconcile_inactive
  | Reconcile_missing
  | Reconcile_unroutable
  | Scope_changed
  | Stall_detected
  | Shutdown_requested
