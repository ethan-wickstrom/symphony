let checked = function
  | Ok value -> value
  | Error message -> Alcotest.fail message

let observed = function
  | Ok value -> value
  | Error error -> Alcotest.fail (Diagnostic.render error)

let milliseconds bits = checked (Milliseconds.parse (Int64.to_string bits))
let count text = checked (Count.parse text)
let instant ticks = Clock.Pure.of_nanoseconds ticks
let decimal time = Count.decimal (Clock.Pure.nanoseconds time)
let epoch = "1970-01-01T00:00:00.000000000000Z"
let day_ticks = Mtime.Span.to_uint64_ns Mtime.Span.day
let native_max = Count.of_uint64_bits (-1L)

let exact_boundaries () =
  Alcotest.(check string)
    "all native bits" "18446744073709551615" (Count.decimal native_max);
  Alcotest.(check (option int64))
    "native round trip" (Some (-1L))
    (Count.to_uint64_bits native_max);
  Alcotest.(check (option int64))
    "no native truncation" None
    (Count.to_uint64_bits (Count.add native_max Count.one));
  let delay = milliseconds Int64.max_int in
  Alcotest.(check string)
    "maximum configuration delay" "9223372036854775807000000"
    (Count.decimal (Milliseconds.nanoseconds delay));
  let later = Clock.Pure.after (instant native_max) delay in
  Alcotest.(check string)
    "unbounded deadline"
    (Z.to_string (Clock_model.after (Clock_model.unsigned (-1L)) Int64.max_int))
    (decimal later);
  Alcotest.(check string)
    "backwards elapsed clamps" "0"
    (Seconds.decimal
       (Clock.Pure.elapsed ~since:later ~until:(instant Count.zero)))

let wall_boundaries () =
  List.iter
    (fun value ->
      match Utc.of_unix_seconds value with
      | Error _ -> ()
      | Ok _ -> Alcotest.fail "invalid wall source accepted")
    [
      Float.nan;
      Float.infinity;
      Float.neg_infinity;
      1e300;
      -1e300;
      253402300800.;
    ];
  Alcotest.(check string)
    "Unix epoch" epoch
    (Utc.rfc3339 (checked (Utc.of_unix_seconds 0.)));
  Alcotest.(check string)
    "year zero boundary" "0000-01-01T00:00:00.000000000000Z"
    (Utc.rfc3339 (checked (Utc.of_unix_seconds (-62167219200.))));
  let wall = checked (Utc.parse "2000-01-01T00:00:00.123456789123Z") in
  let sample = Clock.Pure.{ monotonic = instant native_max; wall } in
  Alcotest.(check (option string))
    "picosecond-preserving nanosecond shift"
    (Some "2000-01-01T00:00:00.123456790123Z")
    (Option.map Utc.rfc3339
       (Clock.Pure.wall_at sample (instant (Count.add native_max Count.one))));
  let duration = Seconds.of_nanoseconds (Count.add native_max native_max) in
  let origin = checked (Utc.parse "0000-01-01T00:00:00Z") in
  let shifted = Utc.shift origin Utc.Later duration in
  Alcotest.(check (option string))
    "multi-chunk UTC agrees with coordinate model"
    (Clock_model.wall_at ~wall:(Utc.rfc3339 origin) ~monotonic:Z.zero
       (Z.mul (Z.of_int 2) (Clock_model.unsigned (-1L))))
    (Option.map Utc.rfc3339 shifted);
  Alcotest.(check (option string))
    "multi-chunk partial inverse"
    (Some (Utc.rfc3339 origin))
    (Option.map Utc.rfc3339
       (Option.bind shifted (fun time -> Utc.shift time Utc.Earlier duration)));
  let huge = Seconds.of_nanoseconds (count ("1" ^ String.make 1000 '0')) in
  Alcotest.(check (option string))
    "unbounded duration stops at UTC horizon" None
    (Option.map Utc.rfc3339 (Utc.shift origin Utc.Later huge))

exception Fixture_defect
exception Fixture_cancel
exception Wall_timer_used

type fault = Healthy | Source_failure | Unexpected_defect

module Native = struct
  type time = Mtime.t

  type t = {
    mutable tick : int64;
    mutable targets : int64 list;
    now_fault : fault;
    timer_fault : fault;
  }

  let check = function
    | Healthy -> ()
    | Source_failure -> raise (Sys_error "fixture clock unavailable")
    | Unexpected_defect -> raise Fixture_defect

  let now t =
    check t.now_fault;
    Mtime.of_uint64_ns t.tick

  let sleep_until t target =
    check t.timer_fault;
    let bits = Mtime.to_uint64_ns target in
    t.targets <- bits :: t.targets;
    t.tick <- bits
end

module Wall = struct
  type t = float ref
  type time = float

  let now t = !t
  let sleep_until _ _ = raise Wall_timer_used
end

let wall_resource value =
  Eio.Resource.T (ref value, Eio.Time.Pi.clock (module Wall))

let native_resource ~tick ~now_fault ~timer_fault =
  let state = Native.{ tick; targets = []; now_fault; timer_fault } in
  (state, Eio.Resource.T (state, Eio.Time.Pi.clock (module Native)))

let diagnostic_site expected = function
  | Ok _ -> Alcotest.fail "expected clock diagnostic"
  | Error error -> (
      match Diagnostic.site error with
      | Diagnostic.Host name ->
          Alcotest.(check string) "source name" expected name
      | Diagnostic.Workflow _ | Diagnostic.Issue _ | Diagnostic.Protocol _ ->
          Alcotest.fail "clock diagnostic lost host site")

let wall_independence () =
  Eio_mock.Backend.run (fun () ->
      let state, mono =
        native_resource ~tick:0L ~now_fault:Healthy ~timer_fault:Healthy
      in
      let clock = Clock_posix.create ~mono ~wall:(wall_resource Float.nan) in
      let now = observed (Clock_posix.now clock) in
      diagnostic_site "wall clock" (Clock_posix.sample clock);
      observed
        (Clock_posix.sleep_until clock (Clock.Pure.after now (milliseconds 1L)));
      Alcotest.(check (list int64))
        "wall failure leaves monotonic timer usable" [ 1_000_000L ]
        (List.rev state.Native.targets))

let native_chunks () =
  Eio_mock.Backend.run (fun () ->
      let state, mono =
        native_resource ~tick:0L ~now_fault:Healthy ~timer_fault:Healthy
      in
      let clock = Clock_posix.create ~mono ~wall:(wall_resource 0.) in
      let deadline = Count.add (Count.of_uint64_bits day_ticks) Count.one in
      observed (Clock_posix.sleep_until clock (instant deadline));
      Alcotest.(check (list int64))
        "bounded targets retain exact deadline"
        [ day_ticks; Int64.add day_ticks 1L ]
        (List.rev state.Native.targets);
      let state, mono =
        native_resource ~tick:(-6L) ~now_fault:Healthy ~timer_fault:Healthy
      in
      let clock = Clock_posix.create ~mono ~wall:(wall_resource 0.) in
      diagnostic_site "monotonic timer"
        (Clock_posix.sleep_until clock
           (instant (Count.add native_max Count.one)));
      Alcotest.(check (list int64))
        "native horizon bounded before error" [ -1L ]
        (List.rev state.Native.targets))

let source_failures () =
  Eio_mock.Backend.run (fun () ->
      let _, mono =
        native_resource ~tick:0L ~now_fault:Source_failure ~timer_fault:Healthy
      in
      let clock = Clock_posix.create ~mono ~wall:(wall_resource 0.) in
      diagnostic_site "monotonic clock" (Clock_posix.now clock);
      let _, mono =
        native_resource ~tick:0L ~now_fault:Healthy ~timer_fault:Source_failure
      in
      let clock = Clock_posix.create ~mono ~wall:(wall_resource 0.) in
      diagnostic_site "monotonic timer"
        (Clock_posix.sleep_until clock (instant Count.one));
      let _, mono =
        native_resource ~tick:0L ~now_fault:Unexpected_defect
          ~timer_fault:Healthy
      in
      let clock = Clock_posix.create ~mono ~wall:(wall_resource 0.) in
      Alcotest.check_raises "unexpected source defect propagates" Fixture_defect
        (fun () -> ignore (Clock_posix.now clock)))

let timer_cancellation () =
  Eio_mock.Backend.run (fun () ->
      let mono = Eio_mock.Clock.Mono.make () in
      let clock = Clock_posix.create ~mono ~wall:(wall_resource 0.) in
      let deadline =
        Clock.Pure.after
          (observed (Clock_posix.now clock))
          (milliseconds Int64.max_int)
      in
      let joined = ref false in
      Alcotest.check_raises "cancel oversized exact deadline" Fixture_cancel
        (fun () ->
          Eio.Switch.run (fun sw ->
              let started, signal = Eio.Promise.create () in
              Eio.Fiber.fork ~sw (fun () ->
                  Fun.protect
                    ~finally:(fun () -> joined := true)
                    (fun () ->
                      Eio.Promise.resolve signal ();
                      observed (Clock_posix.sleep_until clock deadline);
                      Alcotest.fail "oversized deadline finished early"));
              Eio.Promise.await started;
              List.iter
                (fun days ->
                  Alcotest.(check bool)
                    "native timer scheduled" true
                    (Eio_mock.Clock.Mono.try_advance mono);
                  Eio.Fiber.yield ();
                  Alcotest.(check int64)
                    "one day per native target"
                    (Int64.mul (Int64.of_int days) day_ticks)
                    (Mtime.to_uint64_ns (Eio.Time.Mono.now mono)))
                [ 1; 2 ];
              Eio.Switch.fail sw Fixture_cancel;
              Eio.Fiber.yield ()));
      Alcotest.(check bool) "cancel joins timer child" true !joined;
      Alcotest.(check bool)
        "cancel retires pending timer" false
        (Eio_mock.Clock.Mono.try_advance mono))

let tests =
  [
    Alcotest.test_case "exact arithmetic boundaries" `Quick exact_boundaries;
    Alcotest.test_case "wall boundaries and exact shifts" `Quick wall_boundaries;
    Alcotest.test_case "monotonic clock ignores wall failures" `Quick
      wall_independence;
    Alcotest.test_case "native chunks and horizon" `Quick native_chunks;
    Alcotest.test_case "source diagnostics preserve defects" `Quick
      source_failures;
    Alcotest.test_case "oversized timer remains cancelable" `Quick
      timer_cancellation;
  ]

let raw_bits =
  QCheck2.Gen.(
    map
      (fun ((a, b), (c, d)) ->
        Int64.logor (Int64.of_int a)
          (Int64.logor
             (Int64.shift_left (Int64.of_int b) 16)
             (Int64.logor
                (Int64.shift_left (Int64.of_int c) 32)
                (Int64.shift_left (Int64.of_int d) 48))))
      (pair
         (pair (int_range 0 65535) (int_range 0 65535))
         (pair (int_range 0 65535) (int_range 0 65535))))

let nonnegative_bits =
  QCheck2.Gen.map (fun bits -> Int64.logand bits Int64.max_int) raw_bits

let properties =
  [
    QCheck2.Test.make
      ~name:"native ticks agree with unsigned mathematical model" ~count:2000
      raw_bits (fun bits ->
        let value = Count.of_uint64_bits bits in
        Count.to_uint64_bits value = Some bits
        && Count.decimal value = Z.to_string (Clock_model.unsigned bits));
    QCheck2.Test.make ~name:"exact deadline agrees with integer model"
      ~count:2000
      QCheck2.Gen.(pair raw_bits nonnegative_bits)
      (fun (start, delay) ->
        let start_count = Count.of_uint64_bits start in
        let next =
          Clock.Pure.after (instant start_count) (milliseconds delay)
        in
        decimal next
        = Z.to_string (Clock_model.after (Clock_model.unsigned start) delay));
    QCheck2.Test.make ~name:"deadline action and adjacent elapsed compose"
      ~count:2000
      QCheck2.Gen.(pair raw_bits (pair nonnegative_bits nonnegative_bits))
      (fun (start, (a, b)) ->
        let a = milliseconds (Int64.shift_right_logical a 1) in
        let b = milliseconds (Int64.shift_right_logical b 1) in
        let start = instant (Count.of_uint64_bits start) in
        let middle = Clock.Pure.after start a in
        let finish = Clock.Pure.after middle b in
        Clock.Pure.compare (Clock.Pure.after start Milliseconds.zero) start = 0
        && Clock.Pure.compare finish
             (Clock.Pure.after start (checked (Milliseconds.add a b)))
           = 0
        && Count.compare
             (Seconds.nanoseconds
                (Clock.Pure.elapsed ~since:start ~until:finish))
             (Seconds.nanoseconds
                (Seconds.add
                   (Clock.Pure.elapsed ~since:start ~until:middle)
                   (Clock.Pure.elapsed ~since:middle ~until:finish)))
           = 0);
    QCheck2.Test.make ~name:"elapsed agrees with clamped subtraction model"
      ~count:2000
      QCheck2.Gen.(pair raw_bits raw_bits)
      (fun (since, until) ->
        let actual =
          Clock.Pure.elapsed
            ~since:(instant (Count.of_uint64_bits since))
            ~until:(instant (Count.of_uint64_bits until))
        in
        Count.decimal (Seconds.nanoseconds actual)
        = Z.to_string
            (Clock_model.elapsed
               ~since:(Clock_model.unsigned since)
               ~until:(Clock_model.unsigned until)));
    QCheck2.Test.make ~name:"UTC exact action composes and has partial inverses"
      ~count:2000
      QCheck2.Gen.(
        pair (oneof_list [ Utc.Earlier; Utc.Later ]) (pair raw_bits raw_bits))
      (fun (direction, (a, b)) ->
        let wall = checked (Utc.parse "2000-01-01T00:00:00.123456789123Z") in
        let a = Seconds.of_nanoseconds (Count.of_uint64_bits a) in
        let b = Seconds.of_nanoseconds (Count.of_uint64_bits b) in
        let combined = Seconds.add a b in
        let composed =
          Option.bind (Utc.shift wall direction a) (fun next ->
              Utc.shift next direction b)
        in
        let opposite =
          match direction with
          | Utc.Earlier -> Utc.Later
          | Utc.Later -> Utc.Earlier
        in
        Option.map Utc.rfc3339 composed
        = Option.map Utc.rfc3339 (Utc.shift wall direction combined)
        && Option.map Utc.rfc3339 (Utc.shift wall direction Seconds.zero)
           = Some (Utc.rfc3339 wall)
        && Option.map Utc.rfc3339
             (Option.bind composed (fun next ->
                  Utc.shift next opposite combined))
           = Some (Utc.rfc3339 wall));
    QCheck2.Test.make ~name:"wall projection agrees with POSIX coordinate model"
      ~count:2000
      QCheck2.Gen.(
        pair
          (oneof_list
             [
               "0000-01-01T00:00:00.000000000000Z";
               "2000-06-01T12:34:56.123456789123Z";
               "9999-12-31T23:59:59.999999999999Z";
             ])
          (pair raw_bits raw_bits))
      (fun (wall_text, (start, target)) ->
        let wall = checked (Utc.parse wall_text) in
        let sample =
          Clock.Pure.{ monotonic = instant (Count.of_uint64_bits start); wall }
        in
        Option.map Utc.rfc3339
          (Clock.Pure.wall_at sample sample.Clock.Pure.monotonic)
        = Some (Utc.rfc3339 wall)
        && Option.map Utc.rfc3339
             (Clock.Pure.wall_at sample (instant (Count.of_uint64_bits target)))
           = Clock_model.wall_at ~wall:wall_text
               ~monotonic:(Clock_model.unsigned start)
               (Clock_model.unsigned target));
  ]
