<!--
Purpose: document the MORK extension: what it provides, what it needs, and how to build it.
Guarantees: every name here is one the extension registers or a path it ships
  [source: extensions/mork/extension.pl; extensions/mork/mork_ffi/morkspaces.pl].
-->

# MORK: spaces on a Rust trie

MORK is a storage backend. It puts the atoms of a named space in
[MORK](https://github.com/trueagi-io/MORK)'s Rust trie instead of in the
engine's own store, and it reaches it over a text FFI protocol through a
shared object this extension builds.

Nothing in the engine names it. It arrives the way every extension arrives, through
`seam:foreign_space/1`, so the engine asks the seam who owns a space name and
MORK answers for its own. A space this extension does not own leaves every ownership
hook by FAILING rather than refusing, which is what lets the next provider's
clause run.

## What it needs

`extension.pl` declares it, and the engine reads that file rather than running
it:

```prolog
title('Spaces on MORK''s Rust trie, over the FFI').
needs(artefact('mork_ffi/target/release/libmork_ffi.so')).
needs(artefact('mork_ffi/morklib.so')).
needs(predicate(open_shared_object/3)).
entry(engine, 'mork_ffi/morkspaces.pl').
```

Both shared objects are named because the backend needs both: `morkspaces.pl`
opens `libmork_ffi.so` for its global symbols and then loads `morklib.so` for
`mork/3` itself. It throws when either is missing, but SWI PRINTS a load-time
directive that throws and keeps consulting, so before the second need was
declared a tree carrying only the first reported a live backend whose every
call was `Unknown procedure: mork/3`, on every boot, quietly.

The third need is the platform itself. A WebAssembly build mounts this
checkout's files, so the `.so` is there to be SEEN while
`open_shared_object/3` does not exist to open it. The build is fine and the
platform has no dynamic linking, so the honest answer is the same as an unbuilt
tree's: the extension loads nothing and says nothing.

## Building it

```sh
sh extensions/mork/build.sh
```

It needs `cargo`. Without the artefact the extension simply does not load, and a
program that needs it is told so by name rather than failing at the call:

```metta
!(require-extension! mork)
```

That is `lib/lib_mm2/lib_mm2.metta`'s first line, because every operator in that
library is a notation over `&mork`.

## What it provides

Spaces whose names begin `&mork`, plus three builtins declared through the same
seam every extension uses:

| builtin | effect class | what it does |
|---|---|---|
| `mork-add-atoms` | `writesState` | add many atoms in one crossing, rather than one call per atom |
| `mork-flush` | `writesState` | push buffered writes through the FFI |
| `mm2-exec` | `oracleIO` | run MM2 steps in MORK itself |

`lib_mm2` is the MeTTa-level surface over those: five operators over `&mork`,
loaded on demand with `!(import! &self (library lib_mm2))`.

## Testing it

```sh
sh extensions/mork/test.sh
```

`tests/mork_seat.plt` covers the three builtins, the claim over the namespace,
and the failure discipline that lets the next provider's clause run for a space
this extension does not own. Every test in it is conditioned on the extension being
loaded, so an unbuilt tree skips them. That is why `test.sh` says which
configuration it ran and fails a built tree that reported anything less than the
whole file.

`tests/test_missing_artefacts.sh` covers what a built tree cannot reach. It
builds a scratch tree of symlinks whose extension is the shipped `extension.pl` and
whose artefact is genuinely absent, so the loader's own `exists_file` check is
what runs, and then asks for the three properties an absent backend owes: the
boot writes nothing to either stream, the unmet need is recorded by name, and
`!(require-extension! mork)` refuses naming the extension, the missing file and
`extensions/mork/build.sh`. Its third configuration is a negative control: the
same tree under a control file declaring one artefact, which is what this extension
shipped until 2026-08-28, and there the suite above has to go red.

## Measuring it

```sh
sh extensions/mork/bench.sh              # compare against the committed pins
sh extensions/mork/bench.sh --update     # re-pin after reviewing the workload
```

Ten cases at three sizes, each measured inside perf's own control window so the
boot and the setup are outside the count, and each held to
`benchmarks/baseline.json`.

**instructions:u decides every row and CPU is recorded beside it.** SWI's
inference counter retires nothing for work done inside the Rust library, and
this suite shows exactly what that hides: `mork-match-first` and
`mork-match-last` both read 133 inferences per query at 8000 atoms, while CPU
reads 7.4 microseconds for one and 342.7 for the other. Wall clock decides
nothing.

What the comparison says, measured 2026-08-28 at 500, 2000 and 8000 atoms:

| | 500 | 2000 | 8000 |
|---|---|---|---|
| batch add against one add per atom | 0.34x | 0.33x | 0.33x |
| MORK against native, writing | 2.31x | 2.26x | 2.20x |
| MORK against native, first argument bound | 10.31x | 10.34x | 10.32x |
| MORK against native, last argument bound | 46.62x | 133.83x | 611.51x |
| MORK against native, every row | 10.63x | 10.79x | 10.88x |

Writing in batches is worth three of the per-atom form and stays worth it as the
load grows. Everything else is a flat multiple of a native space except the
last-argument query, and that one is the shape of the store: MORK holds an atom
as a PATH, so a bound first argument is a prefix it descends to in constant
time and a bound last argument is a constraint it can only check after walking
the whole space. Per query at 8000 that is 141,876 instructions against
8,470,666.
