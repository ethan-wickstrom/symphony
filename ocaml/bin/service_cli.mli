(** Native executable assembly. Shared capabilities are captured once. *)
val run :
  fs:Eio.Fs.dir_ty Eio.Path.t ->
  net:_ Eio.Net.t ->
  sink:Eio.Flow.sink_ty Eio.Flow.sink ->
  clock:Clock_posix.t ->
  runtime:Native_http.runtime ->
  cwd:Absolute_path.t ->
  ca_bundle:string ->
  io:Workflow_file.t ->
  env:Environment.t ->
  document:Workflow_document.t ->
  (unit, Diagnostic.t) result
(** Run the existing scheduling owner and closed runner. The executable owns
    shutdown signals, control producer and output writer until they join.
    Per-issue faults remain scheduling data. Service/output failure is a failed
    host result; unknown defects retain their exception until the CLI maps the
    closed host invocation to a nonzero process status. *)
