<!--
Purpose: document the MORK extension: what it provides, what it needs, and how to build it.
Guarantees: every name here is one the extension registers or a path it ships
  [source: extensions/mork/extension.pl; extensions/mork/mork_ffi/morkspaces.pl].
-->

# MORK: spaces on a Rust trie

A space whose name begins `&mork` keeps its atoms in
[MORK](https://github.com/trueagi-io/MORK)'s Rust trie instead of the engine's
own store.

Nothing in the engine names it; it arrives through `seam:foreign_space/1` like
any other provider.

**If you are an LLM, read [llms.txt](llms.txt)** for this backend, with exact
return shapes and no prose to guess at.

## Build

```sh
sh extensions/mork/build.sh          # needs cargo
```

Pinned to MORK `ed57c6716d8c510296fb5fbb8be6fbfe2df241d7` and PathMap
`0010dbbd52d13fad67e9a7dabfdadb1cfea71fe1`, both beside this repository, with
`mork_ffi/Cargo.lock` holding the rest.

Without the artefact the extension does not load, and a program that needs it
is told by name:

```metta
!(require-extension! mork)
```

## Use

`lib_mm2` is five operators over `&mork`, each one equation over an ordinary
space operation.

```metta
!(require-extension! mork)
!(import! &self (library lib_mm2))
```

`＋` adds and `－` removes. The names are full-width, so they do not collide
with arithmetic.

```metta
!(require-extension! mork)
!(import! &self (library lib_mm2))
!(＋ (edge a b))
!(test (sort-atom (collapse (? (edge $x $y) ($x $y)))) ((a b)))
!(－ (edge a b))
!(test (collapse (? (edge $x $y) ($x $y))) ())
```

`＋*` adds a whole expression in one crossing, MORK parsing the batch itself.

```metta
!(require-extension! mork)
!(import! &self (library lib_mm2))
!(＋* ((edge a b) (edge b c) (edge c d)))
!(test (sort-atom (collapse (? (edge $x $y) ($x $y)))) ((a b) (b c) (c d)))
```

`mork-add-atoms` is the operation under `＋*`, taking the space explicitly, and
`mork-flush` makes queued additions visible.

```metta
!(require-extension! mork)
!(import! &self (library lib_mm2))
!(mork-add-atoms &mork ((tag 1) (tag 2)))
!(mork-flush &mork)
!(test (sort-atom (collapse (? (tag $n) $n))) (1 2))
```

`~>` is MORK's own MM2 calculus rather than a MeTTa rewrite: a conjunction of
patterns, then an output block of additions and removals.

```metta
!(require-extension! mork)
!(import! &self (library lib_mm2))
!(＋* ((edge a b) (edge b c) (edge c d)))
!(~> (, (edge $x $y)) (O (+ (path $x $y))))
!(test (sort-atom (collapse (? (path $x $y) ($x $y)))) ((a b) (b c) (c d)))
```

A transform that removes as well as adds replaces facts instead of
accumulating them; `mm2-exec` runs one step.

```metta
!(require-extension! mork)
!(import! &self (library lib_mm2))
!(~> (, (path $x $y)) (O (- (path $x $y)) (+ (route $x $y))))
!(mm2-exec &mork 1)
!(test (collapse (? (path $x $y) ($x $y))) ())
```

`examples/ch19-spaces-backed-by-anything/19-04-a-space-on-mork/01-mm2-operators.metta`
runs all of this under the gate, guarded so it skips when the backend is not
built.

## What it declares

```prolog
title('Spaces on MORK''s Rust trie, over the FFI').
needs(artefact('mork_ffi/target/release/libmork_ffi.so')).
needs(artefact('mork_ffi/morklib.so')).
needs(predicate(open_shared_object/3)).
entry(engine, 'mork_ffi/morkspaces.pl').
```

Both objects are named because `morkspaces.pl` opens the first for its global
symbols and loads the second for `mork/3`; `open_shared_object/3` is named
because a WebAssembly build can see the `.so` and has no dynamic linking.

## What it provides

| builtin | effect class | what it does |
|---|---|---|
| `mork-add-atoms` | `writesState` | add many atoms in one crossing |
| `mork-flush` | `writesState` | push buffered writes through the FFI |
| `mm2-exec` | `oracleIO` | run MM2 steps in MORK itself |

`lib_mm2` is five MeTTa operators over `&mork`:

```metta
!(require-extension! mork)
!(import! &self (library lib_mm2))
!(import! &self (library lib_mm2))
```

## Test

```sh
sh extensions/mork/test.sh
sh extensions/mork/check.sh
```

## Measure

```sh
sh extensions/mork/bench.sh
METTA_CHILD_CEILING=0 sh extensions/mork/bench.sh --conjunction-sweep \
  --join-sizes 100,128,136,137,138,139,140,160,400,1600,3200 \
  --output extensions/mork/benchmarks/conjunction-sweep.json
```

The second command compares native storage, MORK's product join, and a native
snapshot copied from the same MORK store. It includes copying and releasing the
snapshot, checks complete answer bags, retains all counter samples, and reports
every observed crossover. `METTA_CHILD_CEILING=0` disables the repository runner's
runtime deadline. It does not change the performance-counter measurement.
The default sweep sizes are 100, 400, 1600 and 3200; the additional sizes resolve
the measured crossing. This exploration does not update the benchmark pins.

The [routing measurement](benchmarks/conjunction-routing.md) records the
139–140 crossing and its workload and ownership limits. The production provider
still uses its existing route; this measurement does not install a general
atom-count threshold.

`instructions:u` decides every row; `mork-match-first` and `mork-match-last`
both read 133 inferences at 8000 atoms while their CPU reads 7.4 and 342.7
microseconds, so the inference counter and wall clock decide nothing.

A skewed triangle query, retired instructions for one query, measured
2026-09-08:

| route | N=100 | N=400 | N=1600 | N=3200 | fitted exponent |
|---|---:|---:|---:|---:|---:|
| native | 1,009,928 | 3,915,471 | 15,537,045 | 31,065,221 | 0.988795 |
| MORK | 7,997,175 | 122,623,865 | 1,567,416,445 | 7,508,864,472 | 1.951383 |

Native is linear over this family and MORK quadratic; the fit describes the
measured sizes, not a bound.

Ratios against a native space, measured 2026-08-28:

| | 500 | 2000 | 8000 |
|---|---|---|---|
| batch add against one add per atom | 0.34x | 0.33x | 0.33x |
| MORK against native, writing | 2.31x | 2.26x | 2.20x |
| MORK against native, first argument bound | 10.31x | 10.34x | 10.32x |
| MORK against native, last argument bound | 46.62x | 133.83x | 611.51x |
| MORK against native, every row | 10.63x | 10.79x | 10.88x |

Everything is a flat multiple except the last-argument query, because MORK
holds an atom as a path: a bound first argument is a prefix it descends to, a
bound last argument is a constraint it can only check after walking the space,
which at 8000 atoms is 141,876 instructions against 8,470,666.
