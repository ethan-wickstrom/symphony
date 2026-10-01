module Http = Native_http.Make (Clock_posix)
module Linear = Linear_tracker.Make (Http) (Clock_posix)
module Config = Config_layer.Make (Tracker_registry)

let ( let* ) = Result.bind
let request_bytes = 1_048_576
let header_bytes = 16_384
let body_bytes = 1_048_576
let wire_bytes = 2_097_152
let timeout_ms = "10000"

let transport ~fs ~net ~clock ~cwd ca_bundle () =
  let site =
    Diagnostic.Workflow { file = ca_bundle; key = None; line = None }
  in
  let fail message =
    Diagnostic.make ~site ~message
      ~remedy:"select a readable PEM CA bundle with --ca-bundle"
  in
  let* file =
    Result.map_error fail (Workflow_path.resolve ~base:cwd ca_bundle)
  in
  let* pem =
    Result.map_error
      (function
        | Workflow_loader.Missing_file _ -> fail "CA bundle is missing"
        | Workflow_loader.Read_error _ -> fail "CA bundle cannot be read"
        | Workflow_loader.Invalid_document _ -> fail "cannot read CA bundle")
      (Workflow_file.read (Workflow_file.make fs) ~file)
  in
  let* trust =
    Result.map_error
      (fun _ -> fail "CA bundle has no valid trust anchors")
      (Http.trust ~pem)
  in
  let* timeout = Result.map_error fail (Milliseconds.parse timeout_ms) in
  let* limits =
    Http.limits ~request_bytes ~header_bytes ~body_bytes ~wire_bytes ~timeout
  in
  Ok (Http.create ~net ~clock ~trust ~runtime:(Http.activate ()) ~limits)

let registry ~fs ~net ~clock ~cwd ~ca_bundle ~warning =
  let io =
    Linear.io ~clock ~http:(transport ~fs ~net ~clock ~cwd ca_bundle)
      ~omitted:(fun omission ->
        warning (Diagnostic.render (Linear_omission.diagnostic omission));
        Ok ())
  in
  Tracker_registry.make [ Tracker_registry.Entry ((module Linear), io) ]

let inspect config =
  let scheduling = Config.scheduling config in
  let names =
    Scheduling_policy.Names.elements (Scheduling_policy.active scheduling)
  in
  let policy = Tracker_read_policy.of_scheduling scheduling in
  Tracker_registry.states (Config.tracker config) ~policy names
