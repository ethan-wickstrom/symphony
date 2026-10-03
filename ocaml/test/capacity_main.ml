module S = Service_test_support.Service_scenario
module M = Capacity_measurements
module Workload = Capacity_fixture

let schema = 1
let total_cycles = Workload.warmup_cycles + Workload.measured_cycles
let worker_event_budget = 20
let cycle_event_budget = 100

let count value =
  match Count.parse (string_of_int value) with
  | Ok value -> value
  | Error message -> invalid_arg message

let checked = function
  | Ok value -> value
  | Error diagnostic -> failwith (Diagnostic.render diagnostic)

let now clock = checked (Clock_posix.now clock)

let elapsed ~previous ~current =
  let previous = Clock.Pure.nanoseconds previous in
  let current = Clock.Pure.nanoseconds current in
  if Count.compare current previous < 0 then failwith "reversed native clock";
  Count.delta ~previous ~current

let json_count value = `Intlit (Count.decimal value)

let memory_json (value : M.memory) =
  let open M in
  `Assoc
    [
      ("live_heap_bytes", json_count value.live_heap_bytes);
      ("fiber_stack_bytes", json_count value.fiber_stack_bytes);
      ("reserved_heap_bytes", json_count value.reserved_heap_bytes);
      ("allocated_bytes", json_count value.allocated_bytes);
    ]

let identity () =
  let gc = Gc.get () in
  let fields =
    [
      ("minor_heap_size", gc.Gc.minor_heap_size);
      ("space_overhead", gc.Gc.space_overhead);
      ("stack_limit", gc.Gc.stack_limit);
      ("custom_major_ratio", gc.Gc.custom_major_ratio);
      ("custom_minor_ratio", gc.Gc.custom_minor_ratio);
      ("custom_minor_max_size", gc.Gc.custom_minor_max_size);
      ("verbose", gc.Gc.verbose);
      ("small_heap_limit", Gc.Tweak.get "small_heap_limit");
      ("mark_stack_prune_factor", Gc.Tweak.get "mark_stack_prune_factor");
    ]
  in
  `Assoc
    [
      ("workload", `String "held-doing-v1");
      ("ocaml_version", `String Sys.ocaml_version);
      ("word_size", `Int Sys.word_size);
      ("global_cap", `Int Workload.max_sessions);
      ("state_cap", `Int Workload.max_sessions);
      ("poll_interval_ms", `Int Workload.poll_interval_ms);
      ("gc", `Assoc (List.map (fun (name, value) -> (name, `Int value)) fields));
    ]

let checkpoint ~sessions phase summary =
  let memory = checked (M.snapshot ()) in
  let fields =
    [
      ("schema", `Int schema);
      ("phase", `String phase);
      ("sessions", `Int sessions);
      ("memory", memory_json memory);
    ]
  in
  let fields =
    if String.equal phase "baseline" then fields @ [ ("identity", identity ()) ]
    else fields
  in
  let fields =
    match summary with
    | None -> fields
    | Some value -> fields @ [ ("summary", value) ]
  in
  print_endline (Yojson.Safe.to_string (`Assoc fields));
  (* Parent-owned RSS pauses occur only at gates outside timed populations. *)
  let expected = "ACK " ^ phase ^ "\n" in
  let received = really_input_string stdin (String.length expected) in
  if not (String.equal received expected) then failwith "invalid capacity ACK";
  memory

type resource_phase = Entered | Closing | Released
type resource = { run : Run_id.t; phase : resource_phase }

type custody = {
  clock : Clock_posix.t;
  sessions : int;
  issue_ids : Issue_id.Set.t;
  event_budget : int;
  mutable events : int;
  mutable resources : resource Issue_id.Map.t;
  mutable origin : Clock.Pure.instant option;
  mutable first_entry : Count.t option;
  mutable all_entries : Count.t option;
  mutable released : int;
}

let bump custody =
  custody.events <- custody.events + 1;
  if custody.events > custody.event_budget then
    failwith "capacity observation budget exhausted"

let origin custody =
  match custody.origin with
  | Some value -> value
  | None -> failwith "resource acquired before service startup"

let resource_event custody event =
  bump custody;
  match event with
  | S.Acquired (S.Run (id, run)) ->
      if not (Issue_id.Set.mem id custody.issue_ids) then
        failwith "unexpected capacity issue";
      if Issue_id.Map.mem id custody.resources then
        failwith "capacity issue acquired twice";
      let time =
        elapsed ~previous:(origin custody) ~current:(now custody.clock)
      in
      custody.resources <-
        Issue_id.Map.add id { run; phase = Entered } custody.resources;
      if custody.first_entry = None then custody.first_entry <- Some time;
      if Issue_id.Map.cardinal custody.resources = custody.sessions then
        custody.all_entries <- Some time
  | S.Closing (S.Run (id, run)) | S.Released (S.Run (id, run)) ->
      let previous =
        match Issue_id.Map.find_opt id custody.resources with
        | Some value when Run_id.equal value.run run -> value.phase
        | Some _ | None -> failwith "capacity closure has no acquisition"
      in
      let phase =
        match event with
        | S.Closing _ ->
            if previous <> Entered then
              failwith "capacity resource closed out of order";
            Closing
        | S.Released _ ->
            if previous <> Closing then
              failwith "capacity resource closed out of order";
            custody.released <- custody.released + 1;
            Released
        | S.Acquired _ -> failwith "capacity closure is an acquisition"
      in
      custody.resources <- Issue_id.Map.add id { run; phase } custody.resources
  | S.Acquired (S.Load _ | S.Read _ | S.Remove _)
  | S.Closing (S.Load _ | S.Read _ | S.Remove _)
  | S.Released (S.Load _ | S.Read _ | S.Remove _) -> ()

type sampling = Startup | Warmup | Measuring | Ending

let empty_samples ~limit =
  match Positive_count.parse (string_of_int limit) with
  | Ok limit -> M.make ~limit
  | Error message -> invalid_arg message

let add duration samples =
  match M.add duration samples with
  | M.Added value -> value
  | M.Full _ -> failwith "capacity numeric sample limit exceeded"

let sample_json samples =
  let quantile numerator denominator =
    match M.quantile ~numerator ~denominator samples with
    | Some value -> json_count value
    | None -> failwith "capacity population has no samples"
  in
  `Assoc
    [
      ("count", json_count (M.count samples));
      ("p50_ns", quantile 1 2);
      ("p95_ns", quantile 95 100);
      ("p99_ns", quantile 99 100);
      ("max_ns", quantile 1 1);
    ]

module Benchmark (Controller : sig
  val controller : S.t
  val custody : custody
end) =
struct
  module P = S.Ports (Controller)

  module Host =
    Service.Make (P.Tracker) (P.Clock) (P.Workspace) (P.Agent) (P.Config)
      (P.Load)

  type t = {
    mutable sampling : sampling;
    mutable startup : M.samples;
    mutable steady : M.samples;
    mutable cycles : M.samples;
    mutable poll_start : Clock.Pure.instant option;
    mutable cycle_count : int;
    mutable started : Run_id.t Issue_id.Map.t;
    mutable completed : Run_id.t Issue_id.Map.t;
    mutable registered : int;
    mutable retired : int;
    mutable peak_running : int;
  }

  let create () =
    {
      sampling = Startup;
      startup = empty_samples ~limit:Controller.custody.event_budget;
      steady = empty_samples ~limit:Controller.custody.event_budget;
      cycles = empty_samples ~limit:Controller.custody.event_budget;
      poll_start = None;
      cycle_count = 0;
      started = Issue_id.Map.empty;
      completed = Issue_id.Map.empty;
      registered = 0;
      retired = 0;
      peak_running = 0;
    }

  let worker_fact facts id run =
    if Issue_id.Map.mem id facts then
      failwith "duplicate capacity worker receipt";
    match Issue_id.Map.find_opt id Controller.custody.resources with
    | Some value when Run_id.equal value.run run ->
        Issue_id.Map.add id run facts
    | Some _ | None ->
        failwith "owner receipt has no acquired capacity resource"

  let started_fact facts id run =
    if not (Issue_id.Set.mem id Controller.custody.issue_ids) then
      failwith "owner started an unexpected capacity issue";
    if Issue_id.Map.mem id facts then
      failwith "duplicate capacity worker receipt";
    begin match Issue_id.Map.find_opt id Controller.custody.resources with
    | Some value when not (Run_id.equal value.run run) ->
        failwith "owner start and resource generation differ"
    | Some _ | None -> ()
    end;
    (* Host entry and port acquisition are independent facts; either may arrive first. *)
    Issue_id.Map.add id run facts

  let require_plateau t =
    Issue_id.Map.iter
      (fun id resource ->
        if resource.phase <> Entered then
          failwith "capacity plateau has a closing worker";
        match Issue_id.Map.find_opt id t.started with
        | Some run when Run_id.equal run resource.run -> ()
        | Some _ | None ->
            failwith "capacity entry and acquisition do not match")
      Controller.custody.resources

  let duration t value =
    match t.sampling with
    | Startup -> t.startup <- add value t.startup
    | Measuring -> t.steady <- add value t.steady
    | Warmup | Ending -> ()

  let poll_end t commands =
    List.iter
      (function
        | Host.Core.Arm_poll _ -> begin
            match (t.poll_start, t.sampling) with
            | Some start, (Warmup | Measuring) ->
                let ticks =
                  elapsed ~previous:start
                    ~current:(now Controller.custody.clock)
                in
                t.poll_start <- None;
                t.cycle_count <- t.cycle_count + 1;
                if t.sampling = Measuring then
                  t.cycles <- add (Seconds.of_nanoseconds ticks) t.cycles;
                if t.cycle_count = Workload.warmup_cycles then
                  t.sampling <- Measuring;
                if t.cycle_count = total_cycles then t.sampling <- Ending
            | Some _, (Startup | Ending) -> t.poll_start <- None
            | None, _ -> ()
          end
        | Host.Core.Load_workflow _
        | Host.Core.Read_tracker _
        | Host.Core.Start_worker _
        | Host.Core.Stop_worker _
        | Host.Core.Remove_workspace _
        | Host.Core.Cancel_request _
        | Host.Core.Cancel_poll _
        | Host.Core.Arm_retry _
        | Host.Core.Cancel_retry _
        | Host.Core.Report _ -> ())
      commands

  let projection t (value : Host.Core.projection) =
    t.peak_running <- max t.peak_running value.Host.Core.running;
    if t.peak_running > Controller.custody.sessions then
      failwith "capacity exceeded its session workload";
    if t.sampling = Warmup || t.sampling = Measuring then begin
      if value.Host.Core.running <> Controller.custody.sessions then
        failwith "capacity lost a held worker";
      if List.length value.Host.Core.owners <> Controller.custody.sessions then
        failwith "capacity projection has extra ownership"
    end

  let observe t event =
    bump Controller.custody;
    begin match event with
    | Host.Initial value ->
        duration t value.Host.elapsed;
        projection t value.Host.projection;
        poll_end t value.Host.commands
    | Host.Transition value ->
        duration t value.Host.elapsed;
        begin match value.Host.input with
        | Host.Core.Poll_due _ ->
            if t.poll_start <> None then failwith "overlapping capacity poll";
            t.poll_start <- Some value.Host.now
        | Host.Core.Worker_started (id, run) ->
            t.started <- started_fact t.started id run
        | Host.Core.Worker_finished completed ->
            let id = P.Agent.completed_issue completed in
            let run = P.Agent.completed_run completed in
            begin match
              Issue_id.Map.find_opt id Controller.custody.resources
            with
            | Some { phase = Released; _ } -> ()
            | Some { phase = Entered | Closing; _ } | None ->
                failwith "owner completion preceded resource release"
            end;
            t.completed <- worker_fact t.completed id run
        | Host.Core.Refresh_requested
        | Host.Core.Workflow_changed
        | Host.Core.Workflow_loaded _
        | Host.Core.Tracker_completed _
        | Host.Core.Request_canceled _
        | Host.Core.Retry_due _
        | Host.Core.Workspace_removed _
        | Host.Core.Shutdown -> ()
        end;
        projection t value.Host.projection;
        poll_end t value.Host.commands
    | Host.Effect (Host.Registered _) -> t.registered <- t.registered + 1
    | Host.Effect (Host.Retired _) -> t.retired <- t.retired + 1
    | Host.Effect (Host.Child_entered _ | Host.Outer_closed _ | Host.Delivered _)
      -> ()
    end;
    S.notify Controller.controller

  let respond issues (S.Pending call) =
    match S.invocation call with
    | S.Loading _ ->
        S.respond call (Ok Workload.config);
        S.close call S.Close_ok
    | S.Reading request ->
        let reply =
          match request with
          | P.Tracker.Contract.States { names; _ } -> begin
              match names with
              | [ "doing" ] -> issues
              | [ "done" ] -> Issue_id.Map.empty
              | _ ->
                  failwith
                    "capacity tracker requested unknown normalized states"
            end
          | P.Tracker.Contract.Ids { ids; _ } ->
              Issue_id.Map.filter (fun id _ -> Issue_id.Set.mem id ids) issues
        in
        S.respond call (Ok reply);
        S.close call S.Close_ok
    | S.Removing _ -> failwith "capacity unexpectedly removed a workspace"
    | S.Running request ->
        let id = Issue.id (P.Agent.issue request) in
        begin match Issue_id.Map.find_opt id Controller.custody.resources with
        | Some { phase = Closing; _ } -> S.close call S.Close_ok
        | Some { phase = Entered; _ } -> ()
        | Some { phase = Released; _ } | None ->
            failwith "pending worker lost custody"
        end

  let rec drive issues joined predicate =
    if predicate () then ()
    else begin
      let revision = S.revision Controller.controller in
      List.iter (respond issues) (S.pending Controller.controller);
      begin match Eio.Promise.peek joined with
      | Some _ -> failwith "capacity service returned before requested gate"
      | None -> ()
      end;
      if not (predicate ()) then
        S.await_change Controller.controller ~after:revision;
      drive issues joined predicate
    end

  let summary t =
    let required = function
      | Some value -> json_count value
      | None -> failwith "missing entry timing"
    in
    `Assoc
      [
        ("acquired", `Int (Issue_id.Map.cardinal Controller.custody.resources));
        ("released", `Int Controller.custody.released);
        ("owner_started", `Int (Issue_id.Map.cardinal t.started));
        ("owner_completed", `Int (Issue_id.Map.cardinal t.completed));
        ("registered", `Int t.registered);
        ("retired", `Int t.retired);
        ("peak_running", `Int t.peak_running);
        ("warmup_cycles", `Int Workload.warmup_cycles);
        ("measured_cycles", `Int Workload.measured_cycles);
        ("events", `Int Controller.custody.events);
        ("event_budget", `Int Controller.custody.event_budget);
        ("pending", `Int (List.length (S.pending Controller.controller)));
        ("service_first_entry_ns", required Controller.custody.first_entry);
        ("service_all_entries_ns", required Controller.custody.all_entries);
        ("startup_reducer_step", sample_json t.startup);
        ("steady_reducer_step", sample_json t.steady);
        ("poll_cycle", sample_json t.cycles);
      ]

  let run ~sw issues t =
    let controls = Eio.Stream.create 1 in
    let joined, signal_joined = Eio.Promise.create () in
    let host =
      Host.create ~clock:Controller.controller ~workspace:Controller.controller
        ~agent:Controller.controller ~load:Controller.controller
        ~report:(fun _ -> failwith "capacity reducer reported a fault")
        ~report_host:(fun _ -> failwith "capacity host reported a fault")
        ~observe:(observe t)
    in
    ignore (checkpoint ~sessions:Controller.custody.sessions "baseline" None);
    Controller.custody.origin <- Some (now Controller.custody.clock);
    Eio.Fiber.fork ~sw (fun () ->
        let result = Host.run ~sw host ~controls Workload.config in
        Eio.Promise.resolve signal_joined result;
        S.notify Controller.controller);
    drive issues joined (fun () ->
        Issue_id.Map.cardinal t.started = Controller.custody.sessions
        && Issue_id.Map.cardinal Controller.custody.resources
           = Controller.custody.sessions
        && t.poll_start = None);
    require_plateau t;
    ignore (checkpoint ~sessions:Controller.custody.sessions "plateau" None);
    t.sampling <- Warmup;
    drive issues joined (fun () -> t.cycle_count = total_cycles);
    ignore (checkpoint ~sessions:Controller.custody.sessions "steady" None);
    Eio.Stream.add controls Host.Shutdown;
    drive issues joined (fun () -> Eio.Promise.peek joined <> None);
    checked (Eio.Promise.await joined);
    if
      Controller.custody.released <> Controller.custody.sessions
      || Issue_id.Map.cardinal t.completed <> Controller.custody.sessions
      || t.registered <> t.retired
      || S.pending Controller.controller <> []
      || Count.compare (M.count t.cycles) (count Workload.measured_cycles) <> 0
    then failwith "capacity service did not close every obligation";
    ignore
      (checkpoint ~sessions:Controller.custody.sessions "joined"
         (Some (summary t)))
end

let main sessions =
  let issues = Workload.issues ~sessions in
  let issue_ids =
    List.fold_left
      (fun found issue -> Issue_id.Set.add (Issue.id issue) found)
      Issue_id.Set.empty issues
  in
  let issues =
    List.fold_left
      (fun found issue -> Issue_id.Map.add (Issue.id issue) issue found)
      Issue_id.Map.empty issues
  in
  Eio_posix.run (fun env ->
      let clock =
        Clock_posix.create
          ~mono:(Eio.Stdenv.mono_clock env)
          ~wall:(Eio.Stdenv.clock env)
      in
      let custody =
        {
          clock;
          sessions;
          issue_ids;
          event_budget =
            (sessions * worker_event_budget)
            + (total_cycles * cycle_event_budget);
          events = 0;
          resources = Issue_id.Map.empty;
          origin = None;
          first_entry = None;
          all_entries = None;
          released = 0;
        }
      in
      S.run ~clock ~observe:(resource_event custody) (fun ~sw controller ->
          let module B = Benchmark (struct
            let controller = controller
            let custody = custody
          end) in
          B.run ~sw issues (B.create ())))

let () =
  Printexc.record_backtrace true;
  let sessions = ref 1000 in
  let spec =
    [
      ( "--sessions",
        Arg.Set_int sessions,
        "Held fake sessions: 1, 10, 100 or 1000" );
    ]
  in
  Arg.parse spec
    (fun _ -> raise (Arg.Bad "unexpected argument"))
    "Native same-service capacity producer";
  try main !sessions
  with error ->
    prerr_endline (Printexc.to_string error);
    prerr_endline (Printexc.get_backtrace ());
    exit 1
