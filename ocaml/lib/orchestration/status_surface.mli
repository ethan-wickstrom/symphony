(** Section 13.7 presentation over the owner's narrow status capability. *)

type method_ = Http_message.method_ = Get | Post | Other of string

type request = Http_message.request = {
  method_ : method_;
  path : string;
  body : string;
}

type response = Http_message.response = {
  status : int;
  content_type : string;
  body : string;
  allow : method_ list;
}

val json : Snapshot.t -> (Json.t, string) result
(** Deterministic baseline state JSON, with exact number lexemes. Oversized JSON
    composition is an expected Error, never an escaped constructor exception. *)

val html : Snapshot.t -> (string, string) result
(** Deterministic escaped HTML, bounded to four MiB. All issue text appears only
    as escaped text; no provider URLs are placed in executable link contexts. *)

module type S = sig
  type source

  val handle : source -> request -> response
  (** GET / and /api/v1/state read exactly one snapshot; GET
      /api/v1/<identifier> includes cleanup ownership. POST /api/v1/refresh uses
      only refresh. Empty/whitespace bodies and an empty JSON object are
      accepted; other bodies return 400 without invoking refresh. Unknown
      routes/issues return 404, unsupported methods on defined routes 405 with
      the exact permitted method in allow, unavailable or oversized projection
      503. All other responses have empty allow. Errors have a JSON envelope.
      Defined method rejection and unknown routes call no port. Other methods
      have no authority regardless of their spelling. *)
end

module Make (Source : Status_source.S) : S with type source = Source.t
