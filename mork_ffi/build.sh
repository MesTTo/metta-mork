#!/bin/sh
# Purpose: build this backend's two artefacts -- the Rust cdylib and the
#   SWI foreign library beside it -- and say which prerequisite is missing
#   rather than failing inside a compiler.
# Assumes:
#   - a nightly Rust toolchain, because PathMap is built here with its
#     `nightly` feature (backends/mork/mork_ffi/Cargo.toml:10)
#   - pkg-config can answer for swipl. Not every SWI build installs swipl.pc;
#     where it is missing this says so by name, which is what the bare
#     `$(pkg-config ...)` could not: it expanded to nothing and gcc failed on
#     a missing SWI-Prolog.h, blaming the wrong thing.
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
for tool in cargo nm pkg-config gcc; do
    command -v "$tool" >/dev/null 2>&1 || missing="$missing $tool"
done
if command -v cargo >/dev/null 2>&1 && ! cargo +nightly --version >/dev/null 2>&1; then
    missing="$missing rust-nightly-toolchain(rustup toolchain install nightly)"
fi
if command -v pkg-config >/dev/null 2>&1 && ! pkg-config --exists swipl; then
    missing="$missing swipl.pc(SWI-Prolog development files)"
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

gcc -shared -fPIC -o morklib.so mork.c $(pkg-config --cflags --libs swipl)

echo "Successfully built mork_ffi"
