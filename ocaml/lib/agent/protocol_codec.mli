(** Consumed stable Codex 0.159.2 methods. Wire payloads remain below the
    runner. *)

type error =
  | Invalid of string
  | Envelope of Protocol_envelope.error
  | Rpc of int64

type call =
  | Initialize of { version : string }
  | Start_thread of { cwd : string; policy : Json.t }
  | Name_thread of { thread : Thread_id.t; name : string }
  | Start_turn of {
      thread : Thread_id.t;
      cwd : string;
      policy : Json.t;
      prompt : string;
    }
  | Interrupt of { thread : Thread_id.t; turn : Turn_id.t }

val method_name : call -> string
val request : id:Protocol_id.t -> call -> (Protocol_envelope.t, error) result

val initialized : unit -> (Protocol_envelope.t, error) result
(** Every encoder uses checked JSON and returns a value on size/shape rejection.
    Initial and continuation turns send the accepted policy explicitly. Thread
    policy is [{approvalPolicy,sandbox}]; turn policy is
    [{approvalPolicy,sandboxPolicy}], with a concrete SandboxPolicy object. *)

val check_turn_policy :
  expected:Json.t -> approval:Json.t -> sandbox:Json.t -> (unit, error) result
(** Compare consumed policy meaning after inserting generated defaults. Writable
    roots compare as a set; opaque additive fields carry no policy. *)

type turn_status = In_progress | Completed | Failed | Interrupted

type turn = {
  id : Turn_id.t;
  status : turn_status;
  error : Diagnostic.t option;
}

type reply =
  | Initialized
  | Thread_started of Thread_id.t
  | Named
  | Turn_started of turn
  | Interrupt_ack

val reply : call -> Json.t -> (reply, error) result
(** Check consumed IDs/shapes and thread policy/cwd/reviewer agreement before
    agent work. Reported cwd remains wire data; launch retains the original
    Path. Remote diagnostics retain the error class, never arbitrary remote
    text. *)

type notification =
  | Turn_started_notice of { thread : Thread_id.t; turn : turn }
  | Turn_completed_notice of { thread : Thread_id.t; turn : turn }
  | Usage of { thread : Thread_id.t; turn : Turn_id.t; absolute : Usage.t }
  | Rate_limits of Json.t
  | Request_resolved of { thread : Thread_id.t; request : Protocol_id.t }
  | Settings of {
      thread : Thread_id.t;
      cwd : string;
      approval : Json.t;
      sandbox : Json.t;
    }
  | Other of {
      method_name : string;
      thread : Thread_id.t option;
      turn : Turn_id.t option;
    }

val notification :
  method_name:string -> Json.t option -> (notification, error) result
(** Known lifecycle/accounting fields are strict. Unknown notifications are
    bounded observations without lifecycle meaning. Usage validates every
    breakdown counter but exports only absolute thread totals. *)

type context = { thread : Thread_id.t option; turn : Turn_id.t option }

type server_action =
  | Reply of {
      context : context;
      response : Protocol_envelope.t;
      tool : string option;
    }
  | Input_required of {
      context : context;
      response : Protocol_envelope.t option;
    }
  | Unsupported of Protocol_envelope.t

val server_request :
  id:Protocol_id.t ->
  method_name:string ->
  Json.t option ->
  (server_action, error) result
(** Grant nothing. All replies use the outer RPC ID; legacy conversation IDs are
    thread context only. User input has no invented answer; MCP is canceled.
    Unknown requests receive method-not-found. Auth refresh/attestation receive
    unsupported and terminate the attempt. The session checks context and owns
    bounded duplicate/replay records before sending a response. *)

val diagnostic : method_name:string -> error -> Diagnostic.t
