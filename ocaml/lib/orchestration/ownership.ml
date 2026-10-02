module type OWNER = sig
  type t
  type instant

  type role =
    | Worker
    | Cleanup
    | Retry_waiting of Retry_id.t * instant
    | Retry_refreshing of Retry_id.t

  val issue : t -> Issue.t
  val role : t -> role
end

module Make
    (Clock : Clock.PURE)
    (Owner : OWNER with type instant = Clock.instant) =
struct
  module Priority = struct
    type t = Owner.t

    (* Only waiting owners have due ranks. The PSQ supplies the ID tie-breaker. *)
    let compare a b =
      match (Owner.role a, Owner.role b) with
      | Owner.Retry_waiting (_, due_a), Owner.Retry_waiting (_, due_b) ->
          Clock.compare due_a due_b
      | ( Owner.Retry_waiting _,
          (Owner.Worker | Owner.Cleanup | Owner.Retry_refreshing _) ) -> -1
      | ( (Owner.Worker | Owner.Cleanup | Owner.Retry_refreshing _),
          Owner.Retry_waiting _ ) -> 1
      | ( (Owner.Worker | Owner.Cleanup | Owner.Retry_refreshing _),
          (Owner.Worker | Owner.Cleanup | Owner.Retry_refreshing _) ) -> 0
  end

  module Queue = Psq.Make (Issue_id.Order) (Priority)

  type t = Queue.t

  let empty = Queue.empty
  let put owner = Queue.add (Issue.id (Owner.issue owner)) owner
  let remove = Queue.remove
  let find = Queue.find
  let fold f owners initial = Queue.fold f initial owners

  let running_ids owners =
    fold
      (fun id owner ids ->
        match Owner.role owner with
        | Owner.Worker | Owner.Cleanup -> Issue_id.Set.add id ids
        | Owner.Retry_waiting _ | Owner.Retry_refreshing _ -> ids)
      owners Issue_id.Set.empty

  let retry_ids owners =
    fold
      (fun id owner ids ->
        match Owner.role owner with
        | Owner.Retry_waiting _ | Owner.Retry_refreshing _ ->
            Issue_id.Set.add id ids
        | Owner.Worker | Owner.Cleanup -> ids)
      owners Issue_id.Set.empty

  let claimed owners =
    Issue_id.Set.union (running_ids owners) (retry_ids owners)

  let next_retry owners =
    match Queue.min owners with
    | None -> None
    | Some (id, owner) -> (
        match Owner.role owner with
        | Owner.Retry_waiting (token, due) -> Some (id, token, due)
        | Owner.Worker | Owner.Cleanup | Owner.Retry_refreshing _ -> None)
end
