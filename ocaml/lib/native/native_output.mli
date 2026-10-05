(** Scoped operator records over one caller-owned sink. *)
module Make (Clock : Clock.S) : sig
  type t

  val emit : t -> event:string -> (string * string) list -> unit
  (** Publish without blocking or suspending on the same Eio domain. Records are
      FIFO ASCII [event=token key=value] lines. Tokens contain only ASCII
      letters, digits, underscore, hyphen or dot. Values escape whitespace,
      equals, backslash and non-ASCII bytes as [\xhh]; keys are unique and
      exclude event. Each encoded line, including LF, is at most 4096 bytes.
      Outstanding records, including the writer's current line, occupy at most
      1048576 bytes. Invalid records, overflow, recorded writer failure and
      post-close publication raise a private rejection. Successful closure
      writes every accepted record; record limits fail the scope instead of
      silently losing records. *)

  val with_output :
    clock:Clock.t ->
    sink:Eio.Flow.sink_ty Eio.Flow.sink ->
    (t -> (unit, Diagnostic.t) result) ->
    (unit, Diagnostic.t) result
  (** Own and join the writer before returning; never close the supplied sink. A
      writer failure rejects further publication and interrupts the callback.
      Known Unix/Eio output errors return fixed redacted diagnostics after
      callback/resource closure; unknown defects retain identity/backtrace. The
      first recorded output failure skips further flushing and wins later clock,
      writer or cancellation-hook faults; a failed sink cannot guarantee
      external delivery of secondary faults. Queued records get one bounded
      flush attempt after callback return or failure, at a fixed 1000 ms
      deadline using exactly the supplied clock. Callback Error and original
      exceptions/backtraces survive writer, cancellation, flush and
      switch-closing failures. Output's own interruption is distinguished from
      external cancellation, which propagates after closure. Sink operations
      must support Eio cancellation; an arbitrary protected sink finalizer has
      no finite-duration guarantee. *)
end
