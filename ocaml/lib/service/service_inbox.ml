type phase = Available | Sealed | Revoked_slot

type 'message t = {
  ready : ('message slot * 'message) Queue.t;
  changed : Eio.Condition.t;
}

and 'message slot = { inbox : 'message t; mutable phase : phase }

type 'message producer = 'message slot
type publication = Published | Duplicate | Revoked
type retraction = Retracted | Previously_retracted | Publication_exists

let create ~changed = { ready = Queue.create (); changed }

let reserve inbox =
  let slot = { inbox; phase = Available } in
  (slot, slot)

let publish producer message =
  match producer.phase with
  | Sealed -> Duplicate
  | Revoked_slot -> Revoked
  | Available ->
      (* Queue the payload once; marking and wakeup cannot suspend. *)
      Queue.add (producer, message) producer.inbox.ready;
      producer.phase <- Sealed;
      Eio.Condition.broadcast producer.inbox.changed;
      Published

let retract slot =
  match slot.phase with
  | Sealed -> Publication_exists
  | Revoked_slot -> Previously_retracted
  | Available ->
      slot.phase <- Revoked_slot;
      Retracted

let consume inbox = Queue.take_opt inbox.ready
let same left right = left == right
