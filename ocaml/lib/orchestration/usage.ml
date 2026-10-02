type t = { input : Count.t; output : Count.t; total : Count.t }

let make ~input ~output ~total = { input; output; total }
let zero = make ~input:Count.zero ~output:Count.zero ~total:Count.zero

let add left right =
  make
    ~input:(Count.add left.input right.input)
    ~output:(Count.add left.output right.output)
    ~total:(Count.add left.total right.total)

let join left right =
  make
    ~input:(Count.max left.input right.input)
    ~output:(Count.max left.output right.output)
    ~total:(Count.max left.total right.total)

let difference ~previous ~current =
  make
    ~input:(Count.delta ~previous:previous.input ~current:current.input)
    ~output:(Count.delta ~previous:previous.output ~current:current.output)
    ~total:(Count.delta ~previous:previous.total ~current:current.total)

let input value = value.input
let output value = value.output
let total value = value.total

type watermark = { run : Run_id.t; thread : Thread_id.t; absolute : t }

let initial ~run ~thread = { run; thread; absolute = zero }
let absolute watermark = watermark.absolute

let observe watermark ~run ~thread ~absolute =
  if not (Run_id.equal watermark.run run) then
    Error "usage report belongs to another run"
  else if not (Thread_id.equal watermark.thread thread) then
    Error "usage report belongs to another thread"
  else
    let accepted = join watermark.absolute absolute in
    let delta = difference ~previous:watermark.absolute ~current:accepted in
    Ok ({ watermark with absolute = accepted }, delta)
