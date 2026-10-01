type entry =
  | Entry :
      (module Tracker_adapter.S with type settings = 's and type io = 'i) * 'i
      -> entry

type adapter =
  | Adapter :
      (module Tracker_adapter.S with type settings = 's and type io = 'i)
      * 's Type.Id.t
      * 'i
      -> adapter

module Kind = Map.Make (String)

module Contract = struct
  module Issue = Issue

  type binding =
    | Binding :
        (module Tracker_adapter.S with type settings = 's and type io = 'i)
        * 's Type.Id.t
        * 's
        * 'i
        -> binding

  type request =
    | States of {
        id : Request_id.t;
        binding : binding;
        policy : Tracker_read_policy.t;
        names : string list;
      }
    | Ids of {
        id : Request_id.t;
        binding : binding;
        policy : Tracker_read_policy.t;
        ids : Issue_id.Set.t;
      }

  type reply = (Issue.t Issue_id.Map.t, Tracker_error.t) result

  let scope (Binding ((module A), _, settings, _)) = A.scope settings

  let secret_names (Binding ((module A), _, settings, _)) =
    A.secret_names settings

  (* One entry identity proves settings equality and fixes the captured IO. *)
  let equal (Binding ((module A), left, a, _)) (Binding (_, right, b, _)) =
    match Type.Id.provably_equal left right with
    | None -> false
    | Some Type.Equal -> A.equal a b
end

type t = adapter Kind.t

let error message =
  Tracker_error.make Tracker_error.Unsupported_tracker_kind
    (Fields.diagnostic ~key:"tracker.kind" message)

let make entries =
  let rec add registry = function
    | [] -> Ok registry
    | Entry ((module A), io) :: rest ->
        if Kind.mem A.kind registry then
          Error (error "duplicate tracker kind in adapter registry")
        else
          let adapter = Adapter ((module A), Type.Id.make (), io) in
          add (Kind.add A.kind adapter registry) rest
  in
  add Kind.empty entries

let configure registry ~env ~kind ~provider =
  let ( let* ) = Result.bind in
  let invalid message =
    Tracker_error.make Tracker_error.Invalid_tracker_config
      (Fields.diagnostic ~key:"tracker.kind" message)
  in
  let* selected = Result.map_error invalid (Fields.credential_text env kind) in
  match Kind.find_opt selected registry with
  | None -> Error (error "unsupported tracker kind")
  | Some (Adapter ((module A), key, io)) ->
      let* settings, public = A.parse ~env provider in
      let* _ = Result.map_error invalid (Fields.text public kind) in
      Ok (Contract.Binding ((module A), key, settings, io), public)

let states (Contract.Binding ((module A), _, settings, io)) ~policy names =
  A.states io settings ~policy names

let execute = function
  | Contract.States { id = _; binding; policy; names } ->
      Result.map Issue_batch.by_id (states binding ~policy names)
  | Contract.Ids
      {
        id = _;
        binding = Contract.Binding ((module A), _, settings, io);
        policy;
        ids;
      } -> A.ids io settings ~policy ids
