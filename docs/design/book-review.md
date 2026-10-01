# Algebra-Driven Design review

Source: Sandy Maguire's [full manuscript](https://github.com/isovector/algebra-driven-design/tree/118aa81a48fb46255dfe4503cbcdee6d893098c9/prose),
commit `118aa81a48fb46255dfe4503cbcdee6d893098c9`.

The review read the introductory prose, both Part 1 design examples and the
good-algebras chapter, both Part 2 implementation chapters, all three Part 3
testing/algebra chapters, and the glossary. This covers the main prose manuscript.
The book's build tools and companion Haskell package were not compiled; embedded
code includes were not expanded into a published edition.

## Changes to Symphony's design

1. **Name observations before equality.** A law is about meaning, not coincidentally
   equal representations. Workspace models observe final directory presence,
   primary result, ordered hook/driver calls, diagnostics and acquisition/release
   multiplicities. Cleanup preserves the filesystem projection after successful
   removal without recreation; it does not reproduce the first execution's trace.
   Core comparisons must observe subsequent generated events and their commands,
   not only an immediately equal status snapshot.

2. **Keep the carrier closed.** Finite sets of unbounded issue IDs have no universal
   absorbing element. Raw retry-entry Set union is lawful as a container operation,
   but merging two due times for one issue is not a valid queue operation. The queue
   uses keyed replacement/removal and a sorted-list observation:

   ```text
   put(i,t2,put(i,t1,q)) = put(i,t2,q)
   remove(i,remove(i,q)) = remove(i,q)
   put(i,t,put(j,u,q)) = put(j,u,put(i,t,q))   when i <> j
   ```

3. **Use multiplicity where it matters.** Command and resource traces are lists,
   the free monoid under concatenation. A set would hide duplicate releases or
   dispatches. The workspace fake counts one release per acquired lease and retains
   cleanup errors while preserving the primary result. Missing configured hooks
   contribute no subprocess effect; configured execution is observable.

4. **Separate observation from authority.** A terminal leader observation does not
   grant reap permission or prove group emptiness. Only one Held-to-Reaping custody
   transition grants the private reaper authority. It runs outside the short mutex;
   Reaping/Reaped handles cannot signal recycled identifiers. OS signal/reap errors
   remain explicit values. Successful signal delivery is not a closed-group proof.
   Grace/drain waits have named bounds; actual POSIX reap has no finite guarantee.

5. **Remove unused generality.** Workspace contracts use checked identifiers and
   live paths, but never Issue.t. Their unused Issue module and equality constraints
   are removed. Tracker, agent and core retain the Issue sharing their operations
   need. Workspace/agent/process Path sharing remains explicit. Lease-to-path
   validation now returns result; an expired lease cannot produce a hidden expected
   exception at that boundary.

   The reference functor's result intentionally shares Path.t, not a concrete
   driver's entire module representation. It aliases the named Path internally;
   its public signature exports only Workspace_path.S plus that type equality.
   A fake's empty-variant representation exposed the overly strong test constraint
   before the live driver existed; the signature was reworked around the required
   capability brand.

6. **Generate valid terms and retain bad raw inputs separately.** Core/law generators
   use smart constructors and source-state/generation witnesses; shrinkers preserve
   those preconditions. Parser fuzzers deliberately generate invalid bytes. Generator
   coverage must name every lifecycle/event/fault constructor and boundary class.
   Late completion/retry events carry generation identities, so same-ID replacement
   cannot consume newly owned work.

7. **State the arithmetic carrier.** Exact nonnegative integer token/runtime totals
   justify monoid laws. Floats do not; saturating machine integers would change the
   intended meaning. Checked bounded configuration addition remains result-valued.
   Absolute-report duplicate, regression and identity-reset behavior needs its own
   laws, independent of addition.

8. **Use discovery as falsification, not proof.** QuickSpec's method suggests bounded
   term enumeration over our OCaml signatures and named observers, without adding
   the Haskell toolchain. Any discovered equation remains a conjecture until justified
   and tested. Distinct IDs/durations remain distinct during generation. Slow seeds
   are retained/replayed; the book's timeout-and-discard testing suggestion cannot
   replace Symphony's required performance evidence.

The updated algebra/interface prose records these corrections. Workspace reference
and policy models pass the full local gate; future core/queue generator coverage
remains an obligation, not a completed proof or conformance claim.
