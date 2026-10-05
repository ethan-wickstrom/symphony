module Make (Clock : Clock.S) = struct
  module Deadline = Deadline.Make (Clock)

  let capacity = 64

  type phase = Dormant | Active | Closed
  type reply_phase = Waiting | Released

  type 'a reply = {
    identity : unit ref;
    publish : ('a, Status_source.unavailable) result Eio.Promise.u;
    mutable phase : reply_phase;
  }

  type request =
    | Snapshot of Snapshot.t reply
    | Refresh of Status_source.refresh reply

  type t = {
    clock : Clock.t;
    changed : Eio.Condition.t;
    timeout : Milliseconds.t;
    mutable phase : phase;
    mutable queued : request list;
    mutable live : request list;
  }

  let create ~clock ~changed ~timeout =
    { clock; changed; timeout; phase = Dormant; queued = []; live = [] }

  let identity = function
    | Snapshot reply -> reply.identity
    | Refresh reply -> reply.identity

  let retire (t : t) (reply : 'a reply) =
    reply.phase <- Released;
    let different request = identity request != reply.identity in
    t.queued <- List.filter different t.queued;
    t.live <- List.filter different t.live;
    Eio.Condition.broadcast t.changed

  let reply t (cell : 'a reply) result =
    match cell.phase with
    | Released -> ()
    | Waiting ->
        retire t cell;
        Eio.Promise.resolve cell.publish result

  let pending (cell : 'a reply) = cell.phase = Waiting

  let close (t : t) =
    t.phase <- Closed;
    List.iter
      (function
        | Snapshot cell -> reply t cell (Error Status_source.Shutting_down)
        | Refresh cell -> reply t cell (Error Status_source.Shutting_down))
      t.live;
    Eio.Condition.broadcast t.changed

  let activate (t : t) =
    match t.phase with
    | Dormant ->
        t.phase <- Active;
        Eio.Condition.broadcast t.changed;
        true
    | Active | Closed -> false

  let take (t : t) =
    match (t.phase, t.queued) with
    | Active, request :: rest ->
        t.queued <- rest;
        Some request
    | (Dormant | Closed), _ | Active, [] -> None

  let rec admit (t : t) =
    match t.phase with
    | Dormant | Closed -> Error Status_source.Shutting_down
    | Active ->
        if List.length t.live < capacity then Ok ()
        else begin
          (* Admission and its waiter use the same domain as the owner. *)
          Eio.Condition.await_no_mutex t.changed;
          admit t
        end

  let call (t : t) make =
    match t.phase with
    | Dormant | Closed -> Error Status_source.Shutting_down
    | Active ->
        let pending : _ reply option ref = ref None in
        Fun.protect
          ~finally:(fun () ->
            match !pending with
            | None -> ()
            | Some cell when cell.phase = Released -> ()
            | Some cell -> retire t cell)
          (fun () ->
            Deadline.run t.clock ~delay:t.timeout
              ~on_error:(fun _ -> Status_source.Clock_unavailable)
              ~on_timeout:(fun () -> Status_source.Timeout)
              (fun () ->
                match admit t with
                | Error error -> Error error
                | Ok () ->
                    let value, publish = Eio.Promise.create () in
                    let cell =
                      { identity = ref (); publish; phase = Waiting }
                    in
                    pending := Some cell;
                    let request = make cell in
                    t.queued <- t.queued @ [ request ];
                    t.live <- request :: t.live;
                    Eio.Condition.broadcast t.changed;
                    Eio.Promise.await value))

  module Source = struct
    type nonrec t = t

    let snapshot t = call t (fun reply -> Snapshot reply)
    let refresh t = call t (fun reply -> Refresh reply)
  end
end
