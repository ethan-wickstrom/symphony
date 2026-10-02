let milliseconds literal =
  match Milliseconds.parse literal with
  | Ok value -> value
  | Error message -> invalid_arg ("invalid backoff constant: " ^ message)

let failure_base = milliseconds "10000"
let continuation = milliseconds "1000"

let failure ~attempt ~cap =
  let target = Positive_count.count attempt in
  let rec double index delay =
    if Count.compare index target >= 0 || Milliseconds.compare delay cap >= 0
    then delay
    else
      match Milliseconds.add delay delay with
      | Error _ ->
          (* Overflow proves the mathematical sum exceeds any checked cap. *)
          cap
      | Ok next when Milliseconds.compare next cap >= 0 -> cap
      | Ok next -> double (Count.add index Count.one) next
  in
  if Milliseconds.compare cap failure_base <= 0 then cap
  else double Count.one failure_base
