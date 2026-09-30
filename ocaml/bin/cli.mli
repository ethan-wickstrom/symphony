val run :
  fs:Eio.Fs.dir_ty Eio.Path.t ->
  cwd:Absolute_path.t ->
  env:Environment.t ->
  argv:string array ->
  out:(string -> unit) ->
  err:Format.formatter ->
  int
(** Command boundary with explicit host capabilities; no tracker
    requests/launches. *)
