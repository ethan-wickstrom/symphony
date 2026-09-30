type category =
  | Unsupported_tracker_kind
  | Invalid_tracker_config
  | Missing_tracker_secret
  | Tracker_request
  | Tracker_status
  | Tracker_response
  | Tracker_pagination
  | Tracker_rate_limited

type t = category * Diagnostic.t

let make c d = (c, d)
let category (c, _) = c
let diagnostic (_, d) = d
