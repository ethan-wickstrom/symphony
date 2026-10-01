(** Source-policy CI executable, using the pinned OCaml 5.5 parser.

    [check_source ROOT ...] recursively scans every supplied root. The default
    root is [ocaml]; its name does not select a directory whitelist. [_opam],
    [_build], [vendor], and [.git] are excluded at every depth. Every [.ml]
    needs a sibling [.mli]; both source kinds are parsed, including new folders.

    The gate rejects Obj/Str/Lwt/Async references, object/class syntax, and
    enumerated partial standard-library operations. It follows explicit module
    aliases, Map/Set functor instances, constrained parameters, and known opens.

    This is a syntax gate, not a totality proof. Dynamic modules, opaque
    external reexports, PPX-generated code, arbitrary user functions, primitive
    externals, and bounds/preconditions of otherwise allowed functions need
    separate review and tests. Explicit raises are not rejected: their interface
    contracts must document permitted defects; syntax cannot prove that an
    exception escapes.

    [--self-test] creates isolated temporary accepted/rejected source fixtures,
    including default-root test helpers, future folders and ignored subtrees.
    Missing roots, empty scans, parse failures, and filesystem failures fail the
    command visibly. Unexpected checker defects also fail visibly with a trace.
    No programmatic interface or ambient filesystem authority is exported. *)
