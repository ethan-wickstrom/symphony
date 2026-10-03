val config : Core_fixture.Config.t
(** Checked native capacity workload; shares A's frozen tracker authority. *)

val issues : sessions:int -> Issue.t list
val max_sessions : int
val poll_interval_ms : int
val warmup_cycles : int
val measured_cycles : int
