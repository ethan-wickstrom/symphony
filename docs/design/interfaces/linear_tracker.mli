(** First adapter. Scope, routing and provider errors stay below Tracker's read kernel. *)

module Make (Http : Http_transport.S) :
  Tracker_adapter.S with type io = Http.t
(** Settings hold Http.credential abstractly. GraphQL query strings are constants;
    untrusted issue/scope/filter data enters JSON variables. Pagination is atomic.
    Publish the §11.2 profile before enabling real dispatch. *)
