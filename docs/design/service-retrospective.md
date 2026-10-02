# Service architecture review

The pure reducer was easier to understand in isolation. This change improves its
integration boundary: the same reducer now drives scoped effects, and its actual
delivered events are checked against the existing independent model. It also adds
substantial cancellation machinery. Passing simulation does not make this a live
agent service; the closed Codex runner remains the next unverified boundary.

## What improved

- Resource completion belongs to the runner. Only its private constructor can
  certify that its workspace/process scopes closed. The host never invents a
  completion to make shutdown finish.
- Reserved one-shot notifications remove the blocking publication edge between
  finalizers and a failed owner. The bound follows admitted effects.
- One private `Service_failure` register selects the first fatal observation and
  redacts secondary errors. The owner joins without rethrowing the selection;
  the caller reads it afterward. The reference model takes the first failed
  observation and retains later independent exception reports in order.
- `Scenario.run` owns finalizer permissions and the child switch. Its constructor
  cannot be called without the bracket. Actor exit opens permissions before child
  joins; only actual finalizers emit release receipts.
- `Core_bridge` is shared by pure and effectful drivers. Both compare actual
  ordered commands and projections with the independent event model, without
  duplicating correspondence logic.

## Introduced defects and exposed assumptions

| Finding | Origin | Correction |
| --- | --- | --- |
| Host reporter defects disappeared without an earlier fatal primary | New service error sink | Record the first reporter defect and continue report drainage |
| Aggregate order and IO leaves were lost | New service decoder; an IO-order bug also existed in native cleanup | One shared Eio decoder, tested against real switch finalizers |
| Independent effects sharing IO payloads lost reports | New arbitration reused cleanup deduplication across effects | Record each occurrence once; stop rethrowing selected failures through the owner |
| A later cancellation replaced an earlier owner failure | New service arbitration | One canonical first-failure register |
| Observer failure replaced a received clock error | New observation ordering | Commit fatal closure before observer callbacks |
| Already canceled fake operations acquired resources | New fake-port lifecycle | Enter the release scope before acquisition; resolved runner cancellation acquires nothing |
| Failed test actor stranded finalizer gates and lost its exception | New simulator ownership | Scoped controller; RED before fix in `eio-actor-red.log` |
| Pure fixture had no constructible workspace path | Existing fixture assumption exposed by effectful tests | Checked fixture path under a callback; native containment claims remain separate |
| Type clients depended on executable wrapper names | Existing test integration exposed by shared fixtures | Link the shared library's actual CMIs; retain negative-type and unchanged-CMI checks |
| Example-runner help could fall through into properties | Existing runner pattern copied into new code | Separate example, property and replay executables |

## Wrong turns

The initial mailbox design bounded queue size without checking whether a producer
could block while holding a resource required by shutdown. Backpressure belongs
at admission here, not on closure publication.

I represented caller and owner failure separately before defining their ordering
law. More catch/restore branches followed. Even after introducing the shared
register, I retained the rethrow/recapture path and used deduplication to conceal
it. That was the wrong abstraction: observations have identity, exception values
do not. The owner now stops on the recorded fact and joins; only the caller
restores it. No exception comparison is needed across independent effects.

I also treated test control code as scaffolding. Its blocked finalizers are real
Eio resources. The test actor needs the same ownership discipline as production.
The actor-failure regression demonstrated the mistake before the API replacement.

The first failure-register property reused error identities. That could miss
same-kind replacement. Distinct observations now reject a deliberate last-wins
mutation, shrinking it to `error,error`; restored production code passes.

Review also exposed Eio normalization: IO exception wrappers are rebuilt, and
multiple distinct failures can retain the same error/context fields. Suppressing
a set of matching identities erased a later failure. Ordered occurrence
subtraction removes only the captured primary within its own cleanup aggregate.
It must not subtract a different effect's primary. Direct and actual-service
regressions fail against the previous implementation; the strengthened list model
also detects the loss when separate observations reuse one exception value.

I pushed once before inspecting a repeated reference gate's exit status. That
violated the gate. An unchanged real-clock timer test missed its margin by 267 ms;
both its isolated replay and the complete reference gate passed at the same seed
989296. The test was not weakened. Gate results must be inspected before pushing;
a successful command launch is not a successful check.

## Hunches and next falsifiers

Two existing wall-clock tests failed once locally, then passed unchanged: the
reference retry timer and the native watchdog's fake target. Host scheduling
pressure is plausible but unmeasured. Their tight real-time margins are
reproducibility debt; distinguish bounded termination from speed measurement in
the next capacity gate.

The interpreter remains large. Admission, cancellation and observation are closely
ordered; splitting them mechanically could obscure the very edges under test.
The private failure register is a justified boundary. A generic effect framework
is not justified by this one interpreter.

The logical ownership queue and physical handle registry look redundant, but
record different facts. Cancellation cannot remove a physical obligation before
closure. Consolidating them would erase that distinction.

The sampled controller has only three issue IDs and short prefixes. It may miss
wide fan-out, long retry histories and native reap interactions. The next tests
must falsify those assumptions: a measured 1000-session workload, then actual
Codex protocol/closure failures. More seeds alone do not establish those claims.

[Eio's switch contract](https://ocaml-multicore.github.io/eio/eio/Eio/Switch/index.html)
joins child fibers before release hooks. That rules out registering the actor's
gate release as a switch hook: the children need those gates to finish first.
