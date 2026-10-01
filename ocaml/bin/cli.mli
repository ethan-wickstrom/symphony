val run :
  fs:Eio.Fs.dir_ty Eio.Path.t ->
  net:_ Eio.Net.t ->
  clock:Clock_posix.t ->
  cwd:Absolute_path.t ->
  env:Environment.t ->
  argv:string array ->
  out:(string -> unit) ->
  err:Format.formatter ->
  int
(** Explicit host capabilities. Doctor/dry-run/workspace perform no tracker
    request, trust read or crypto activation. Tracker inspection alone reads
    configured active issues through authenticated HTTPS. *)
