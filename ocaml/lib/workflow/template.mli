(** Strict bounded Jinja over Jingoo 1.5.4's public AST/interpreter API. No
    filesystem, process, clock, environment, or user-supplied callables. *)

type t
type error = Parse_error of Diagnostic.t | Render_error of Diagnostic.t
type attempt = First | Follow_up of Positive_count.t

val compile : file:Workflow_path.t -> string -> (t, error) result
(** Unknown syntax/filter fails. Supports text, interpolation, field/array index
    access, if/elif/else, array/map loops, null/bool/string/integer literals,
    not/and/or, equality, ordering, membership, and conditional expressions.
    Filters: length, join, lower, upper, trim, literal replace, default. No
    arithmetic, floating-point literals, assignment, includes, macros, dynamic
    calls, engine loop helpers, or keyword filter arguments. Empty source
    compiles empty; Config_layer selects the fallback. Lexer comments, raw
    blocks, string escapes, and whitespace trimming are supported.

    Source: 256 KiB. AST: 16,384 nodes, depth 64. These limits are part of this
    dialect, not operator configuration. Exceeding one produces a named error.
*)

val render : t -> issue:Issue.t -> attempt:attempt -> (string, error) result
(** Same checked inputs produce the same bytes. Missing variable/property,
    lookup beneath null/scalar, and invalid/out-of-range array indexes fail.
    Known null renders empty and default handles only null. Strings are
    verbatim; collections render compact JSON, preserving exact numeric kinds
    and lexemes. Follow-up counts and JSON numerals remain exact; numeric
    comparisons are exact. Map iteration binds keys with one name, key/value
    pairs with two names; array iteration takes one name. Bindings have lexical
    scope.

    Checked input: 1 MiB, 32,768 nodes, depth 64. Intermediate strings/final
    output: 1 MiB each. Render work: 2,000,000 units, including expressions,
    statements, every loop iteration (even empty bodies), and
    lookup/filter/comparison work. Output size is checked before append or
    expanding allocation. Bounded count conversion permits a temporary decimal
    string up to twice its accepted byte limit before checking the exact decimal
    length.

    AST sequence has identity/associativity when both sides stay within the same
    sufficient budgets. Source concatenation is not an algebra operation.
    Expected engine/private boundary failures become diagnostics; host
    cancellation and unexpected defects are not caught as template errors. *)
