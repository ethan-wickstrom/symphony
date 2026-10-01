module type PURE = sig
  type instant
  type sample = { monotonic : instant; wall : Utc.t }

  val compare : instant -> instant -> int
  val after : instant -> Milliseconds.t -> instant
  val elapsed : since:instant -> until:instant -> Seconds.t
  val wall_at : sample -> instant -> Utc.t option
end

module type S = sig
  module Pure : PURE

  type t

  val now : t -> (Pure.instant, Diagnostic.t) result
  val sample : t -> (Pure.sample, Diagnostic.t) result
  val sleep_until : t -> Pure.instant -> (unit, Diagnostic.t) result
end

module Pure = struct
  type instant = Count.t
  type sample = { monotonic : instant; wall : Utc.t }

  let of_nanoseconds ticks = ticks
  let nanoseconds ticks = ticks
  let compare = Count.compare
  let after time delay = Count.add time (Milliseconds.nanoseconds delay)

  let elapsed ~since ~until =
    Seconds.of_nanoseconds (Count.delta ~previous:since ~current:until)

  let wall_at sample time =
    if compare time sample.monotonic < 0 then
      Utc.shift sample.wall Utc.Earlier
        (elapsed ~since:time ~until:sample.monotonic)
    else
      Utc.shift sample.wall Utc.Later
        (elapsed ~since:sample.monotonic ~until:time)
end
