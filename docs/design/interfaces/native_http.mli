(** Native HTTPS mechanism over H1's public one-shot connection codec. Tracker
    policy and pagination remain above this port. *)

type runtime
(** One host-owned, deferred process crypto bootstrap, shared by every registry
    and clock instantiation. Its representation contains no client transport. *)

val defer : unit -> runtime
(** Pure capture: does not query or change the global RNG. The first admitted
    [post] lazily adopts an existing default generator, or installs the
    supported Getentropy default if none exists. Concurrent forces initialize
    once through [Eio.Lazy] and retain the same witness for this host's
    lifetime.

    Initialization is short and cancellation-protected. A cancellation already
    observed by the read deadline prevents initialization; cancellation after
    admission is delivered by the enclosing read scope after initialization.
    Unknown bootstrap defects retain identity/backtrace and are memoized.

    TLS uses Mirage's process-global default. The host must pass this same value
    to all clients and retain any preexisting generator's owner. No background
    fiber, descriptor, reset, or guarantee against a foreign global replacement.
*)

module Make (Clock : Clock.S) : sig
  include Http_transport.S

  type trust
  type nonrec runtime = runtime
  type limits

  val trust : pem:string -> (trust, Diagnostic.t) result
  (** Pure PEM parsing into nonempty, explicit X509 trust anchors. Anchors may
      be self-signed roots, intermediate certificates or pins; this constructor
      does not impose X509.Validation.valid_ca's self-signed-root restriction.
      The host first reads a bounded trust file through an explicit Eio
      filesystem capability. Production and fake-CA tests use this same
      constructor and TLS path. No ambient trust discovery or authentication
      bypass. *)

  val limits :
    request_bytes:int ->
    header_bytes:int ->
    body_bytes:int ->
    wire_bytes:int ->
    timeout:Milliseconds.t ->
    (limits, Diagnostic.t) result
  (** Check positive budgets before allocation or arithmetic. Request bytes are
      encoded JSON; header bytes bound the outbound request line/fields and,
      independently, the response head; body bytes are decoded bytes; wire bytes
      include chunk framing. Every accepted request stays within all four
      independent budgets. At the wire bound, one constant-space byte probe
      distinguishes EOF from excess data; excess is rejected without reaching
      the codec or retained response. Response headers stay fail-closed. *)

  val create :
    net:_ Eio.Net.t ->
    clock:Clock.t ->
    trust:trust ->
    runtime:runtime ->
    limits:limits ->
    t
  (** Pure capability capture. [post] alone forces the shared runtime, samples
      the supplied clock and uses the network. Failed request/header preflight
      does not force crypto. A foreign replacement or removal of the witnessed
      generator is a redacted diagnostic before network use. TLS checks the
      credential's destination host/IP against the explicit anchors, with a
      checked wall sample and HTTP/1.1 ALPN.

      One child switch owns each socket, TLS flow and input/output pump. An
      exact monotonic post deadline spans DNS, connect, handshake and body. The
      adapter separately applies its whole-read deadline across pages.

      Expected I/O, TLS and parser errors become redacted diagnostics. Unknown
      exceptions and external cancellation retain identity and the backtrace
      supplied by the dependency after closure. Capture callback defects before
      H1's [Exn] carrier can erase their backtrace. EOF is success only after
      the codec exposes no pending parse error. Redirects are rejected; no proxy
      or raw wire logging. *)
end
