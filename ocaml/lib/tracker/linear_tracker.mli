(** Linear's checked settings and read implementation share one lexical module.
    Instantiate once; use Config for validation and the enclosing adapter for
    IO. *)

module Make (Http : Http_transport.S) (Clock : Clock.S) : sig
  module Config : Tracker_adapter.CONFIG
  (** Offline settings construction. Scope is [linear:] followed by SHA256 of
      the length-prefixed endpoint/project bytes, excluding the API key. It
      exposes neither endpoint query/path text nor project text. Credential
      rotation preserves scope; equal settings imply equal scopes. Selected
      credentials and declared source values are quarantined from public routing
      and core settings; aliases/literals cannot bypass exact-value quarantine.
      Active/terminal policy belongs to each request, never frozen settings. *)

  type settings = Config.settings
  type io

  val io :
    http:(unit -> (Http.t, Diagnostic.t) result) ->
    clock:Clock.t ->
    omitted:(Linear_omission.t -> (unit, Diagnostic.t) result) ->
    io
  (** Pure capability capture. The HTTP factory is deferred and invoked at most
      once per nonempty whole read, inside its deadline scope. A successful
      monotonic admission invokes it once; an initial clock error invokes none.
      Empty reads invoke no factory, clock or provider operation. The factory
      may load bounded trust material and activate crypto for an explicit read;
      service hosts may supply an already-ready scoped driver. No memoization or
      global driver cache. The sink consumes one bounded omission at a time;
      there is no stored warning list. An expected sink Error does not change
      the read result. Sink cancellation/defects preserve identity/backtrace.

      Each complete read owns a switch and races its operation against the
      supplied Clock.sleep_until at one fixed 30-second deadline. Expected clock
      failure is a read error. Http bounds each post; the adapter also counts
      cumulative pages, nodes and bytes. No ambient clock or detached timer. *)

  include Tracker_adapter.S with type settings := settings and type io := io
end
