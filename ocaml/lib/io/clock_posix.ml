module Pure = Clock.Pure

type t = {
  mono : Eio.Time.Mono.ty Eio.Resource.t;
  wall : float Eio.Time.clock_ty Eio.Resource.t;
}

type source = Monotonic | Wall | Timer

let create ~mono ~wall =
  {
    mono :> Eio.Time.Mono.ty Eio.Resource.t;
    wall :> float Eio.Time.clock_ty Eio.Resource.t;
  }

let source_name = function
  | Monotonic -> "monotonic clock"
  | Wall -> "wall clock"
  | Timer -> "monotonic timer"

let diagnostic source message remedy =
  Diagnostic.make ~site:(Diagnostic.Host (source_name source)) ~message ~remedy

let read source run =
  try Ok (run ())
  with (Sys_error _ | Unix.Unix_error _ | Eio.Io _) as error ->
    Error
      (diagnostic source (Printexc.to_string error)
         "check the supplied clock capability and host timer availability")

let native_now t =
  Eio.Fiber.check ();
  read Monotonic (fun () ->
      Count.of_uint64_bits (Mtime.to_uint64_ns (Eio.Time.Mono.now t.mono)))

let now t = Result.map Pure.of_nanoseconds (native_now t)

let sample t =
  Result.bind (now t) (fun monotonic ->
      Result.bind
        (read Wall (fun () -> Eio.Time.now t.wall))
        (fun seconds ->
          match Utc.of_unix_seconds seconds with
          | Ok wall -> Ok { Pure.monotonic; Pure.wall }
          | Error message ->
              Error
                (diagnostic Wall message
                   "set the wall-clock source to a finite timestamp in years \
                    0000 through 9999")))

let max_native_tick = Count.of_uint64_bits (Mtime.to_uint64_ns Mtime.max_stamp)

let max_native_sleep =
  Count.of_uint64_bits (Mtime.Span.to_uint64_ns Mtime.Span.day)

let min_count a b = if Count.compare a b <= 0 then a else b

let horizon () =
  Error
    (diagnostic Timer "native monotonic clock horizon reached before deadline"
       "repair the monotonic clock source or restart the host")

let sleep_until t deadline =
  let deadline = Pure.nanoseconds deadline in
  let rec sleep () =
    Result.bind (native_now t) (fun current ->
        if Count.compare current deadline >= 0 then Ok ()
        else
          let remaining = Count.delta ~previous:current ~current:deadline in
          let headroom =
            Count.delta ~previous:current ~current:max_native_tick
          in
          let chunk =
            min_count remaining (min_count headroom max_native_sleep)
          in
          if Count.compare chunk Count.zero = 0 then horizon ()
          else
            (* OCaml cannot express this inequality proof: the selected chunk
               is bounded by native headroom, so its target must fit uint64. *)
            match Count.to_uint64_bits (Count.add current chunk) with
            | None -> horizon ()
            | Some target ->
                Result.bind
                  (read Timer (fun () ->
                       Eio.Time.Mono.sleep_until t.mono
                         (Mtime.of_uint64_ns target)))
                  sleep)
  in
  sleep ()
