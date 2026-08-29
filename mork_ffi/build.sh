#!/bin/sh
# Purpose: build this backend's two artefacts -- the Rust cdylib and the
#   SWI foreign library beside it -- and say which prerequisite is missing
#   rather than failing inside a compiler.
# Assumes:
#   - a nightly Rust toolchain, because PathMap is built here with its
#     `nightly` feature (extensions/mork/mork_ffi/Cargo.toml:10)
#   - swipl-ld, which ships with SWI-Prolog and is therefore available wherever
#     the engine is. morklib.so is loaded with use_foreign_library/1
#     (morkspaces.pl:323), so it is an extension loaded INTO SWI, which is
#     exactly what swipl-ld builds and what engine/reader.so and the chapter 19
#     C examples already use (check.sh). This used to be
#     `gcc -shared -fPIC ... $(pkg-config --cflags --libs swipl)`, the only
#     place in the tree asking pkg-config, and not every SWI build installs
#     swipl.pc: where it is absent that expanded to NOTHING and gcc failed on a
#     missing SWI-Prolog.h, blaming the wrong thing. Measured 2026-08-28: both
#     spellings produce a 15768-byte object exporting the same ten symbols and
#     the same install hook.
#     extensions/cmetta keeps --dump-runtime-variables instead, and correctly: it
#     calls PL_initialise (cmetta.c:1353) and so EMBEDS SWI in a C program,
#     the opposite direction, which swipl-ld does not build.
# Guarantees:
#   - "Successfully built" is printed only when both artefacts exist and the
#     cdylib really exports rust_mork. Without `set -e` this script ran every
#     line regardless and printed that message unconditionally, and its
#     `nm -D ... | grep rust_mork` decided nothing because its exit status
#     was discarded.
#   - it runs the same from any working directory.
# Fails when:
#   - any prerequisite is absent: all of them are named at once, so a fresh
#     machine learns the whole list in one run rather than one per attempt.
# Decides:
#   - `-C target-cpu=native`, so the artefact is tuned for THIS machine and
#     cannot be copied to another. That is right for a build run beside the
#     checkout that uses it, and it is why no wheel or package ships it.
# Open Obligations:
#   To Do: None
#   Hacks: None
#   Future Enhancements: None

set -eu

HERE=$(cd -- "$(dirname -- "$0")" && pwd)
cd "$HERE"

missing=''
for tool in cargo nm swipl-ld; do
    command -v "$tool" >/dev/null 2>&1 || missing="$missing $tool"
done
# swipl-ld drives a C compiler rather than being one, so a tree with swipl-ld
# and no compiler fails inside it. check.sh's build_engine_reader tests the same
# pair for the same reason.
if ! command -v cc >/dev/null 2>&1 &&
   ! command -v gcc >/dev/null 2>&1 &&
   ! command -v clang >/dev/null 2>&1; then
    missing="$missing a-C-compiler(cc,gcc-or-clang)"
fi
if command -v cargo >/dev/null 2>&1 && ! cargo +nightly --version >/dev/null 2>&1; then
    missing="$missing rust-nightly-toolchain(rustup toolchain install nightly)"
fi
if [ -n "$missing" ]; then
    echo "mork_ffi/build.sh: not built, missing:$missing" >&2
    exit 1
fi

RUSTFLAGS="-C target-cpu=native" cargo +nightly build -p mork_ffi --release

# The engine reaches this library through exactly one entry point, so its
# absence means the crate built into something the backend cannot call. Checked
# rather than printed: `grep -q` and `set -e` make this a gate, where the
# original piped nm into a bare grep whose status nothing read.
if ! nm -D ./target/release/libmork_ffi.so | grep -q ' rust_mork$'; then
    echo "mork_ffi/build.sh: libmork_ffi.so does not export rust_mork;" >&2
    echo "  the crate built but not into a library this backend can load" >&2
    exit 1
fi

swipl-ld -shared -o morklib.so mork.c

echo "Successfully built mork_ffi"
