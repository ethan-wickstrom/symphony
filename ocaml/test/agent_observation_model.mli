(** History oracle. Facts are recomputed from accepted entries; token totals are
    the componentwise supremum of the complete accepted report list. *)

type totals = { input : Z.t; output : Z.t; total : Z.t }

type event =
  | Preparing
  | Workspace_ready
  | Rendering
  | Starting
  | Session_started of { session : string; thread : string; turn : string }
  | Turn_started of { session : string; turn : string }
  | Turn_completed of { session : string; turn : string }
  | Output of { session : string; name : string; message : string option }
  | Usage_report of { thread : string; turn : string; absolute : totals }
  | Rate_limits of string
  | Unsupported_tool of string

type progress = {
  run : string;
  sequence : Z.t;
  emitted : int;
  now : int;
  event : event;
}

type acceptance = Accepted | Ignored

type error =
  | Wrong_phase
  | Wrong_session
  | Wrong_thread
  | Wrong_turn
  | Wrong_run
  | Future_time
  | Regressing_time
  | Turn_limit

type view = {
  sequence : Z.t;
  phase : string;
  session : string option;
  thread : string option;
  turn : string option;
  turn_count : int;
  last_event : string option;
  last_message : string option;
  last_activity : int option;
  usage : totals;
  rate_limits : string option;
}

type t

val empty : max_turns:int -> t
val view : t -> view
val zero : totals
val observe : t -> progress -> (t * acceptance * totals, error) result
val queue : t -> turn:string -> (t * acceptance, error) result
val need : t -> string option
val answer : t -> turn:string -> (t, error) result
