(** Native trusted-shell and process-group custody, with injected time. *)

module Make (Clock : Clock.S) : sig
  include Agent_process.S with module Path = Workspace_path_posix.Public

  val create : clock:Clock.t -> report:(Diagnostic.t -> unit) -> t
  (** No IO at construction. Streams yield at most 4096 bytes per read. Cleanup
      revokes and joins pending stream/exit operations before requesting TERM,
      waits at most 1000 ms for the direct child, then requests KILL and closes
      group custody. Both streams drain concurrently for at most 100 ms before
      all pipes close. Every later release obligation runs even when time, IO,
      or reporting fails. Kernel reap has no finite bound. Unexpected defects
      propagate after closure; callback failure takes precedence. A successful
      callback exposes the first cleanup defect or, if none occurred, returns
      the first expected cleanup error. Native IO/launch failures return
      redacted diagnostics. The environment is exactly the checked allowlisted
      child bindings. No stream bytes, trusted command, or environment values
      are logged. *)
end
