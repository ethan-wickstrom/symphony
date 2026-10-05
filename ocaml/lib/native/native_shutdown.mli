(** Scoped POSIX shutdown signals. The callback owns all service producers. *)
type signal = Interrupt | Terminate

val with_signal :
  report:(Diagnostic.t -> unit) ->
  (signal Eio.Promise.t -> ('a, Diagnostic.t) result) ->
  ('a, Diagnostic.t) result
(** Latch the first SIGINT/SIGTERM. Handlers only wake a nonblocking self-pipe;
    they never call Eio or operator sinks. Repeated signals coalesce while the
    callback drains. Join the reader before restoring handlers and closing both
    descriptors. Every acquired obligation closes after partial setup failure. A
    callback Error or original exception/backtrace survives teardown defects;
    success exposes the first defect after all cleanup. Secondary reports are
    redacted and cannot replace that primary. Process-global handlers require
    one invocation at the executable composition boundary. *)
