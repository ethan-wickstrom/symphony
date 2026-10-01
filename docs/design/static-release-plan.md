# Native release closure

Status: design approved for investigation; no static release artifact has been
built or verified. This is a build foundation before the orchestrator slice.

## Observed macOS artifact

On 2026-10-01, a copied snapshot of `ocaml/_build/default/bin/main.exe` had:

| Observation | Value |
| --- | --- |
| Format | arm64 Mach-O executable |
| Size | 12,608,968 bytes |
| SHA-256 | `ec92acb90e248cc412e253d9d71da7db31d86ed1914162dfad20fd4fc9e7997f` |
| Deployment target | macOS 26.0 |
| Build SDK | macOS 26.5 |
| Non-system import | `/opt/homebrew/opt/gmp/lib/libgmp.10.dylib` |
| System import | `/usr/lib/libSystem.B.dylib` |
| System loader | `/usr/lib/dyld` |

`otool -L` showed no libffi or other non-system dylib. The imported GMP dylib
itself imports only `libSystem`. The binary therefore needs a separately
installed GMP dylib and fails the documented macOS single-file release target.
These observations identify this development artifact, not a source-to-binary
attestation or a clean-host deployment test. Local evidence is in
`/private/tmp/symphony-macos-closure-0ioddz7t/evidence.json`.

The installed Zarith 1.14 archive reports these C dependencies:

```text
-lzarith -L/opt/homebrew/Cellar/gmp/6.3.0/lib -lgmp
```

macOS links the OCaml runtime and application archives into one executable but
keeps its system loader and system libraries. Apple's installed `ld(1)` states
that its global `-static` mode is for kernel builds. Linux musl is a separate
fully static ELF target. Existing macOS/Ubuntu CI checks the development build;
Ubuntu CI does not prove musl linkage. The Burrito release workflow builds the
Elixir implementation and provides no OCaml release evidence.

## Isolated target profiles

Start with `macos-arm64`, minimum OS **26.0**, SDK **26.5**, and
`linux-x86_64-musl`. Pin each target's compiler, SDK/toolchain identity, native
source archives and hashes, package recipes, opam lock, and reviewed vendor
inputs. A lower macOS minimum requires a new complete dependency build and
tests on that OS; changing the final link flag cannot certify old archives.

Each profile owns a clean opam root/switch, native dependency prefix and Dune
build directory. It does not reuse development `.cmxa` files, Homebrew
archives, global linker flags or ambient `pkg-config` search paths. Build
environment changes exist only in that profile's child processes. Pin GMP
6.3.0 source and build static-only, position-independent `libgmp.a` plus its
matching generated `gmp.h` for the profile's ABI and portable CPU baseline.
Run GMP's own checks. GMP documents ABI-specific headers and the need to
choose a distribution CPU baseline. [GMP package-build notes](https://gmplib.org/manual/Notes-for-Package-Builds)

Keep the published Zarith 1.14 source unchanged. Its normal configure step
discovers headers through the target prefix's `gmp.pc`; clear
`PKG_CONFIG_PATH` and restrict `PKG_CONFIG_LIBDIR` to the profile. Its
**package-local make recipe** supplies this `LIBS` value, with the actual
profile archive path:

```text
-cclib /target-prefix/lib/libgmp.a -ldopt /target-prefix/lib/libgmp.a
```

`ocamlmklib -cclib` forwards the archive to `ocamlopt -a`; `-ldopt` forwards
the same archive to Zarith's shared-stub link. Neither option changes the
installed development package. Zarith's native build becomes:

```text
ocamlmklib -g -failsafe -o zarith <Zarith .cmx files>
  -cclib /target-prefix/lib/libgmp.a
  -ldopt /target-prefix/lib/libgmp.a
```

The expected fresh native metadata is `-lzarith` followed by the exact GMP
archive path, with no `-lgmp`, Homebrew path or GMP dylib. Reject the build if
`ocamlobjinfo` disagrees. Do not put a bare archive pathname in `gmp.pc`'s
`Libs`: OCaml 5.5 `ocamlmklib` classifies `.a` arguments as C input objects;
that would archive GMP as a member of `libzarith.a` instead of recording a
dependency. Ordinary `-L... -lgmp` is also insufficient evidence of exact
archive selection. [Zarith configure](https://github.com/ocaml/Zarith/blob/release-1.14/configure),
[Zarith build rules](https://github.com/ocaml/Zarith/blob/release-1.14/project.mak),
[OCaml 5.5 ocamlmklib](https://github.com/ocaml/ocaml/blob/5.5/tools/ocamlmklib.ml)

## Link-order evidence and required physical check

The OCaml manual specifies that `.cmxa` files retain their `-cclib` and
`-ccopt` dependencies and restore them on subsequent links.
[OCaml native compiler](https://ocaml.org/manual/5.5/native.html)

The current Dune action was inspected with
`opam exec --switch=. -- dune rules bin/main.exe --format=json` from `ocaml/`.
It invokes this switch's `ocamlopt.opt`, includes the installed
`zarith/zarith.cmxa`, and supplies no `-noautolink`, `-cclib` or `-ccopt`
override. Thus the development action uses the stored Homebrew/GMP metadata.
The derived rule and complete argv are retained in
`/private/tmp/symphony-macos-main-rule.json` and
`/private/tmp/symphony-macos-main-link-argv.txt`. This query did not execute the
linker.

The installed 5.5 compiler source confirms that the native link places OCaml
objects before the recorded C inputs, preserves the reported dependency
order, then appends the OCaml runtime and native system libraries. In this
profile, the relevant portion must be:

```text
<OCaml objects and archives> -lzarith /target-prefix/lib/libgmp.a
<OCaml runtime archive> <target system libraries>
```

This order lets GMP resolve references introduced by Zarith. Darwin's
installed `ld(1)` describes repeated archive searching; GNU `ld` searches an
archive where it appears, so the dependent-before-dependency order also
matters on Linux. [OCaml native link assembly](https://github.com/ocaml/ocaml/blob/5.5/asmcomp/asmlink.ml),
[OCaml C linker invocation](https://github.com/ocaml/ocaml/blob/5.5/utils/ccomp.ml),
[GNU linker archive search](https://sourceware.org/binutils/docs/ld/Options.html)

This is source/manual evidence, not a successful release link. The dedicated
foundation must capture Dune's actual native action and the compiler's
verbose C-link command, verify the exact archive and order, then inspect and
run the resulting artifact. Retain the link map, archive hash, toolchain
identities, final executable hash and gate results. Do not repair linkage
with `-noautolink`, forced archive loading, installed metadata edits or a
copied dylib.

## Artifact gates

For macOS arm64:

1. Build every input for the declared ABI and macOS 26.0 minimum; retain the
   SDK identity. Reject deployment-target mismatch diagnostics.
2. Inspect all load commands. Initially allow only `/usr/lib/dyld` and
   `/usr/lib/libSystem.B.dylib`; any additional system import needs an
   explicit profile entry. Reject non-system dylibs, unresolved relative or
   `@rpath` imports, and runtime paths into the build prefix.
3. Copy only the executable into a macOS 26.0 test host without Homebrew or
   an opam installation. Run the available CLI, trusted TLS/DNS, process,
   cancellation and workspace-hook checks through that artifact. Extend the
   same gate to dispatch and the JSON API when those capabilities land.

For Linux x86-64 musl:

1. Build the OCaml compiler/runtime and all native dependencies with the
   pinned musl target toolchain; no glibc-built archive may enter the link.
2. Use the profile's static link mode, then inspect ELF headers and dynamic
   tags. Require the declared architecture, no `PT_INTERP` and no
   `DT_NEEDED`. A compiler flag alone cannot pass this gate.
3. Run the executable in a clean target image without OCaml, GMP shared
   libraries or a dynamic loader. Supply only declared configuration,
   certificates and external tools. Test DNS/TLS, subprocesses, hooks and
   cancellation; add dispatch/API checks as they become available.

Codex, Bash and any workflow-required Git remain external executables.
Credentials, `WORKFLOW.md` and the explicit CA bundle remain operator inputs.
They do not justify non-system shared libraries inside the Symphony artifact.

## Release source and notices

GMP 6.3.0 offers LGPLv3 or GPLv2 with later-version options. Choose the LGPLv3
combined-work route for this distribution; retain the upstream license
choices in the source package. Zarith's OCaml linking exception does not
replace GMP's terms. [GMP copying conditions](https://gmplib.org/manual/Copying)

Publish GMP notice, LGPLv3/GPL texts, the exact GMP source and any changes,
Symphony/application sources, dependency sources and lock data, and the
target recipes needed to rebuild and relink with a modified compatible GMP.
Keep this material beside each release, identified by hashes. Verify the
rebuild/relink procedure. This implements the static combined-work source
route in LGPLv3 Section 4; a single deployment executable does not mean a
binary-only release. [LGPLv3 Section 4](https://www.gnu.org/licences/lgpl.html)

## Build order

1. Commit the isolated profile manifests, pinned native source inputs and
   package-local Zarith recipe.
2. Build and verify the macOS arm64 artifact and exact link closure; keep the
   development switch unchanged.
3. Build and verify Linux musl independently.
4. Make the artifact gates release requirements and retain their manifests.

Both release targets remain unverified until their physical builds and clean
host gates pass.
