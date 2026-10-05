(** Scoped, loopback-only HTTP transport. Requests carry no scheduler authority.
*)
module Make (Clock : Clock.S) : sig
  val with_server :
    net:'net Eio.Net.t ->
    clock:Clock.t ->
    port:Http_port.t ->
    ready:(int -> unit) ->
    handler:(Http_message.request -> Http_message.response) ->
    (unit -> ('a, Diagnostic.t) result) ->
    ('a, Diagnostic.t) result
  (** Bind [127.0.0.1] before invoking [ready] or the callback. Port zero
      selects an ephemeral port. A failed bind never invokes either callback.

      Each connection serves one request, then closes. Limits are 64 concurrent
      connections, 16 KiB request headers, 64 KiB decoded body, 96 KiB incoming
      wire bytes, 8 MiB response body, 128-byte content type, and a five-second
      whole-connection deadline measured by [clock], including time waiting for
      the handler. Query strings and fragments are rejected; path components are
      URI-decoded exactly once. After writing, the connection half-closes its
      send side and drains unread bytes within the same wire budget and
      deadline. Hostile or truncated input may exhaust either bound; no further
      request reaches the handler.

      Returning from the callback stops admission and joins all accepted client
      scopes before releasing the listener. External cancellation cancels and
      joins them. Expected peer parse, timeout and socket failures are local to
      that connection. Expected listener/clock failures return a redacted
      diagnostic after cancellation and joins. Unknown defects preserve their
      original exception and backtrace. A callback [Error] or original exception
      remains primary over independent server closure faults.

      Laws: binding failure implies zero callback entries; each accepted socket
      has exactly one scoped owner; return implies no listener or client
      remains; a malformed first request grants zero handler authority;
      fragmenting one valid request within the byte/deadline bounds preserves
      its parsed value and response; raising from a callback preserves physical
      exception identity after join. *)
end
