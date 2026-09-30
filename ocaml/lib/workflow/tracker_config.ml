type entry =
  | Entry : (module Tracker_adapter.CONFIG with type settings = 's) -> entry

type adapter =
  | Adapter :
      (module Tracker_adapter.CONFIG with type settings = 's) * 's Type.Id.t
      -> adapter

module Contract = struct
  module Issue = Issue

  type binding =
    | Binding :
        (module Tracker_adapter.CONFIG with type settings = 's)
        * 's Type.Id.t
        * 's
        -> binding

  type request =
    | States of { id : Request_id.t; binding : binding; names : string list }
    | Ids of { id : Request_id.t; binding : binding; ids : Issue_id.Set.t }

  type reply = (Issue.t Issue_id.Map.t, Tracker_error.t) result

  let scope (Binding ((module A), _, s)) = A.scope s
  let secret_names (Binding ((module A), _, s)) = A.secret_names s

  (* A named registry identity proves settings equality; no casts or reparsing. *)
  let equal (Binding ((module A), ka, a)) (Binding (_, kb, b)) =
    match Type.Id.provably_equal ka kb with
    | None -> false
    | Some Type.Equal -> A.equal a b
end

type t = adapter list

let error message =
  Tracker_error.make Tracker_error.Unsupported_tracker_kind
    (Fields.diagnostic ~key:"tracker.kind" message)

let make entries =
  let rec unique names = function
    | [] ->
        Ok (List.map (fun (Entry a) -> Adapter (a, Type.Id.make ())) entries)
    | Entry (module A) :: rest ->
        if List.mem A.kind names then
          Error (error "duplicate tracker kind in adapter registry")
        else unique (A.kind :: names) rest
  in
  unique [] entries

let configure entries ~env ~kind ~active ~terminal ~provider =
  let rec select = function
    | [] -> Error (error "unsupported tracker kind")
    | Adapter ((module A), key) :: rest ->
        if A.kind <> kind then select rest
        else
          Result.map
            (fun s -> Contract.Binding ((module A), key, s))
            (A.parse ~env ~active ~terminal provider)
  in
  select entries
