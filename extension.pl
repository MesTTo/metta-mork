% Purpose: declare MORK's build and platform requirements before entry loading.
%
% The artefact is what `sh build.sh` produces, and its absence means the
% backend was not built rather than that anything is wrong. The predicate need
% is the platform door: a WebAssembly build mounts this checkout's files, so
% the .so is there to be SEEN while open_shared_object/3 does not exist to
% open it -- the build is fine and the platform has no dynamic linking, so the
% honest answer is the same as an unbuilt tree's. Before that need existed the
% backend raised two ERROR lines through every boot of the Node binding, which
% its old stderr parser matched neither of and absorbed in silence.
%
% Both shared objects are declared because the backend needs both.
% morkspaces.pl opens libmork_ffi.so
% for its global symbols and then use_foreign_library's morklib.so for mork/3
% itself. SWI prints a raising load-time directive and continues consulting;
% loading_loudly/1 now turns that diagnostic into an exception before the
% engine records a loaded seat. Declaring both needs still matters: an unbuilt
% backend loads and prints nothing, while require-extension! names the missing
% file and the command that builds it
% [tested: extensions/mork/tests/test_missing_artefacts.sh; commit=WORKTREE].
%
% morkspaces.pl still raises when it is reached another way -- git-import! and
% an embedded process that never ran this loader -- which is the half-loaded
% case these needs cannot see.

title('Spaces on MORK''s Rust trie, over the FFI').
needs(artefact('mork_ffi/target/release/libmork_ffi.so')).
needs(artefact('mork_ffi/morklib.so')).
needs(predicate(open_shared_object/3)).
entry(engine, 'mork_ffi/morkspaces.pl').
