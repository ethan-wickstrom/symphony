(** Scoped byte/process/workspace peers, independent of the client and runner.
*)

type gate

val gate : unit -> gate
val release : gate -> unit
val await : gate -> unit

type event =
  | Launch of { cwd : string; command : string; env : (string * string) list }
  | Write of Json.t
  | Read_stdout of int
  | Read_stderr of int
  | Process_closing
  | Process_closed
  | Workspace_acquired
  | After_run
  | Lease_closing
  | Lease_released

type trace

val trace : unit -> trace
val record : trace -> event -> unit
val events : trace -> event list
val wait_event : trace -> (event -> bool) -> unit
val writes : trace -> Json.t list

module Path : Workspace_path.S

val with_path : (Path.t -> 'a) -> 'a
val cwd : string

type peer

module Process : Agent_process.S with module Path = Path and type process = peer

val process :
  ?close:gate ->
  ?fault:exn ->
  ?on_launch:(peer -> unit) ->
  trace ->
  (peer -> Json.t -> unit) ->
  Process.t

val send : peer -> string -> unit
val stderr : peer -> string -> unit
val eof : peer -> unit
val fault : peer -> exn -> unit
val read_error : peer -> Diagnostic.t -> unit

module Contract : Workspace_manager.PURE with module Path = Path
module Workspace : Workspace_manager.S with module Contract = Contract

type cleanup_stage = After_hook | Report

val workspace :
  ?after_run:gate ->
  ?release:gate ->
  ?fault:cleanup_stage * exn ->
  trace ->
  Workspace.t

val reference : unit -> Contract.reference
val issue : ?title:string -> unit -> Issue.t

val settings :
  ?read_ms:int -> ?turn_ms:int -> ?max_turns:int -> unit -> Agent_settings.t

val environment : Environment.child
val prompt_file : Workflow_path.t
val fresh_run : unit -> Run_id.t
val version : string
val title : string
val json : string -> Json.t
val obj : (string * Json.t) list -> Json.t
val text : string -> Json.t
val field : string -> Json.t -> Json.t
val text_value : Json.t -> string
val method_name : Json.t -> string option
val reply : peer -> Json.t -> Json.t -> unit
val notify : peer -> string -> Json.t -> unit
val request : peer -> id:Json.t -> string -> Json.t -> unit
val thread_result : Json.t
val turn : ?error:Json.t -> id:string -> status:string -> unit -> Json.t

val completed :
  peer ->
  ?thread:string ->
  ?error:Json.t ->
  id:string ->
  status:string ->
  unit ->
  unit

val server : turn:(peer -> Json.t -> unit) -> peer -> Json.t -> unit

type mono

val clock : unit -> mono * Clock_posix.t
val advance : mono -> int -> unit
