type 'a t = Returned of 'a | Raised of exn * Printexc.raw_backtrace

let capture f =
  try Returned (f ()) with ex -> Raised (ex, Printexc.get_raw_backtrace ())

let resolve = function
  | Returned value -> value
  | Raised (ex, bt) -> Printexc.raise_with_backtrace ex bt
