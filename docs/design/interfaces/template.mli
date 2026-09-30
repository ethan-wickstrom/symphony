(** Strict bounded prompt engine. Known null is distinct from missing.
    No filesystem, process, clock, environment, or user-supplied callable access. *)

type t
type error = Parse_error of Diagnostic.t | Render_error of Diagnostic.t
type attempt = First | Follow_up of Positive_count.t
val compile : file:Workflow_path.t -> string -> (t, error) result
(** Unknown syntax/filter is Error, never silently discarded. Empty source compiles
    an empty template. Config_layer selects the fallback. Dialect: bounded strict Jinja. *)

val render : t -> issue:Issue.t -> attempt:attempt -> (string, error) result
(** Same checked inputs produce the same bytes. Missing variable/property fails.
    A known null is permitted; loops and output are bounded. Internal AST sequence
    has identity/associativity only when both sides stay within identical resource
    budgets. Source concatenation is not an algebra operation: tokenization can change. *)
