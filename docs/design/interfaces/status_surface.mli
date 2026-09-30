(** Section 3.1 component. Read-only projection plus a coalesced refresh trigger. *)

type method_ = Get | Post | Other of string
type request = { method_ : method_; path : string; body : string }
type response = { status : int; content_type : string; body : string }
type refresh = Queued | Coalesced
type unavailable = Timeout | Shutting_down

module type SOURCE = sig
  type t
  val snapshot : t -> (Snapshot.t, unavailable) result
  (** Ask the owner to project with a fresh clock sample; bounded wait, no cached state. *)

  val refresh : t -> (refresh, unavailable) result
  (** Queue an owner event; never mutate scheduling state from an HTTP fiber. *)

end

module type S = sig
  type source
  val handle : source -> request -> response
  (** /, GET /api/v1/state, GET /api/v1/<identifier>, POST /api/v1/refresh.
      JSON error envelope for unknown issue/route, unsupported methods and unavailable
      source. Read formatting cannot affect scheduling. Escape untrusted HTML. *)

  val json : Snapshot.t -> Json.t
  val html : Snapshot.t -> string
  (** Same snapshot gives same output; JSON and HTML reflect the same facts.
      Encode exact counts as JSON numbers, not lossy floating-point totals. *)

end

module Make (Source : SOURCE) : S with type source = Source.t
