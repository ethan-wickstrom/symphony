(** Private single-domain Service notification mechanism.

    All operations run on the owner's Eio domain. Producers are scoped fibers on
    that domain; native threads never receive these capabilities. No operation
    below suspends. The owner alone reserves, retracts and consumes slots.

    A payload exists once, in an immutable queued envelope with its slot. The
    slot stores publication status only, never the payload. Each reservation
    permits at most one publication; there is no unrestricted [add] operation.
    This bounds queued notifications by reserved slots, not by a constant
    independent of admitted jobs. *)

type 'message t
type 'message slot
type 'message producer
type publication = Published | Duplicate | Revoked
type retraction = Retracted | Previously_retracted | Publication_exists

val create : changed:Eio.Condition.t -> 'message t
(** Capture the explicit wake capability; start no fiber or effect. The owner
    shares [changed] with its coalesced control-source facts. *)

val reserve : 'message t -> 'message slot * 'message producer
(** Mint a fresh slot and its publication-only capability. The owner records the
    slot before forking its producer. The producer cannot consume or retract it.
    Distinct reservations have distinct slot identities. *)

val publish : 'message producer -> 'message -> publication
(** Fresh -> published: append an immutable (slot, payload) envelope once, then
    broadcast [changed]. Published/consumed -> [Duplicate], with no change;
    retracted -> [Revoked]. The first payload wins. Publish, FIFO insertion and
    broadcast form one non-suspending step. Cancellation cannot replace a
    pending payload.

    Model law: consume order equals successful publication order. Repeated
    publication never increases pending notifications. *)

val retract : 'message slot -> retraction
(** Revoke an unpublished slot after failed admission or after the enclosing
    resource has closed without producing this optional notification. Retraction
    never removes a published notification.

    Law: retract(retract(slot)) leaves the same state; subsequent publication of
    a retracted slot is [Revoked]. Service must not retract a live job's
    required closure slot to pretend its resource has closed. *)

val consume : 'message t -> ('message slot * 'message) option
(** Remove the oldest immutable envelope and return its slot and payload.
    Consumption does not inspect a mutable slot payload or require an impossible
    phase branch. The slot remains sealed and retains no payload. Empty
    consumption is identity. Registry retirement occurs only for a matching
    consumed closure envelope, in the same non-suspending owner step. Entry
    consumption does not retire a worker handle. *)

val same : 'message slot -> 'message slot -> bool
(** Slot identity is reflexive, symmetric and transitive. It is independent of
    payload equality and cannot be forged through this signature. *)
