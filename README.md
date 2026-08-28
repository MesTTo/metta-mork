<!--
Purpose: document the MORK seat: what it provides, what it needs, and how to build it.
Guarantees: every name here is one the seat registers or a path it ships
  [source: extensions/mork/extension.pl; extensions/mork/mork_ffi/morkspaces.pl].
-->

# MORK: spaces on a Rust trie

MORK is a storage backend. It puts the atoms of a named space in
[MORK](https://github.com/trueagi-io/MORK)'s Rust trie instead of in the
engine's own store, and it reaches it over a text FFI protocol through a
shared object this seat builds.

Nothing in the engine names it. It arrives the way every seat arrives, through
`seam:foreign_space/1`, so the engine asks the seam who owns a space name and
MORK answers for its own. A space this seat does not own leaves every ownership
hook by FAILING rather than refusing, which is what lets the next provider's
clause run.

## What it needs

`extension.pl` declares it, and the engine reads that file rather than running
it:

```prolog
title('Spaces on MORK''s Rust trie, over the FFI').
needs(artefact('mork_ffi/target/release/libmork_ffi.so')).
needs(predicate(open_shared_object/3)).
entry(engine, 'mork_ffi/morkspaces.pl').
```

Two needs, and the second is the one worth explaining. A WebAssembly build
mounts this checkout's files, so the `.so` is there to be SEEN while
`open_shared_object/3` does not exist to open it. The build is fine and the
platform has no dynamic linking, so the honest answer is the same as an unbuilt
tree's: the seat loads nothing and says nothing.

## Building it

```sh
sh extensions/mork/build.sh
```

It needs `cargo`. Without the artefact the seat simply does not load, and a
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
