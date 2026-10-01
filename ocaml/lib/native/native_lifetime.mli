type t
(** Semantic resource ownership shared by cwd loans and pending pipe operations.
    Managed FD references do not cancel/join an escaped operation. *)

type 'e failure = Closed | Rejected of 'e

val create : report:(exn * Printexc.raw_backtrace -> unit) -> t
(** Initially Held, with no admitted scopes. The private reporter observes
    secondary scope defects; it must not render untrusted exception payloads. *)

val held : t -> bool
(** Snapshot only. Authority is granted exclusively by [with_scope]. *)

val with_scope :
  t -> (sw:Eio.Switch.t -> ('a, 'e) result) -> ('a, 'e failure) result
(** Atomically admit while Held. Each admitted scope retains ownership until its
    child fibers/resources close, then unregisters once. Closing/Released grants
    no callback or effect. Owner cancellation becomes Closed; other
    cancellation/defects retain identity and original backtrace. Callback Error
    and Raised cancel non-daemon children before joining them. Primary failure
    outranks release/reporter defects; callback Ok exposes a scope defect only
    after closure. The explicit result carrier makes that precedence total. *)

val close : t -> unit
(** Held -> Closing -> Released. Cancel and join every admitted scope before
    returning; repeated close is identity. Cancellation-handler defects cannot
    skip later cancellation or any join; the first defect propagates afterward.
    Protected against caller cancellation. Call only outside an admitted scope;
    joining one's own scope would deadlock. This private restriction is enforced
    structurally by Store and Process assembly, not offered to user callbacks.
    OCaml has no linear lifetime types, so one hidden gate enforces this law. *)
