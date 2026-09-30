type category =
  | Unsupported_tracker_kind
  | Invalid_tracker_config
  | Missing_tracker_secret
  | Tracker_request
  | Tracker_status
  | Tracker_response
  | Tracker_pagination
  | Tracker_rate_limited
type t
val make : category -> Diagnostic.t -> t
val category : t -> category
val diagnostic : t -> Diagnostic.t
