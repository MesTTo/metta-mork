#!/bin/sh
# Purpose: build this backend, which is the crate in mork_ffi/ beside this file.
# Assumes: the MORK and PathMap checkouts the crate reaches by relative path are
#   present at their validated revisions; the repository's own build.sh
#   provisions them and checks the pins.
# Open Obligations:
#   To Do: None
#   Hacks: None
#   Future Enhancements: None

set -eu
HERE=$(cd -- "$(dirname -- "$0")" && pwd)
exec sh "$HERE/mork_ffi/build.sh"
