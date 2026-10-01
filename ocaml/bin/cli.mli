val run :
  fs:Eio.Fs.dir_ty Eio.Path.t ->
  clock:Clock_posix.t ->
  cwd:Absolute_path.t ->
  env:Environment.t ->
  argv:string array ->
  out:(string -> unit) ->
  err:Format.formatter ->
  int
(** Command boundary with explicit host capabilities. Local inspection performs
    no tracker requests, hooks, or agent launches. *)
