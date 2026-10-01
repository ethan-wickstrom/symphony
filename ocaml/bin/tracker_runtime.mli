(** Host assembly: one Linear module owns parsing and credential-bound reads. *)

module Config :
  Config_layer.S
    with type tracker = Tracker_registry.Contract.binding
     and type registry = Tracker_registry.t

val registry :
  runtime:Native_http.runtime ->
  fs:Eio.Fs.dir_ty Eio.Path.t ->
  net:_ Eio.Net.t ->
  clock:Clock_posix.t ->
  cwd:Absolute_path.t ->
  ca_bundle:string ->
  warning:(string -> unit) ->
  (Tracker_registry.t, Tracker_error.t) result
(** Pure closure capture; no trust-file, clock, RNG or network operation. Each
    explicit nonempty read constructs its transport within the read deadline.
    All transports retain the host's same deferred crypto runtime; a read never
    creates or replaces its process bootstrap. Warnings contain only
    Linear_omission's bounded redacted projection. *)

val inspect : Config.t -> (Issue_batch.t, Tracker_error.t) result
(** Read configured active states through the captured binding. Output is the
    ordered normalized batch; no secrets or arbitrary native payloads. *)
