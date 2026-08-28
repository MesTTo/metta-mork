% This backend's control file; see extensions/python/extension.pl for the model.
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
% BOTH shared objects are declared, because the backend needs both and a
% raising entry does not stop a consult. morkspaces.pl opens libmork_ffi.so
% for its global symbols and then use_foreign_library's morklib.so for mork/3
% itself, and it throws when either is missing -- but SWI PRINTS a raising
% load-time directive and carries on, so ensure_loaded/1 still succeeds and
% the loader below it still records the seat LOADED. A tree carrying only the
% first artefact therefore reported a live backend whose every call was
% `Unknown procedure: mork/3`, on every boot, quietly [measured 2026-08-28:
% twelve of the seat's own tests raised that, the other twelve passed].
% Declaring the second is what makes that tree answer the same way an unbuilt
% one does: nothing loads, nothing prints, and require-extension! names the
% missing file and the command that builds it
% [tested: extensions/mork/tests/test_missing_artefacts.sh].
%
% morkspaces.pl still raises when it is reached another way -- git-import! and
% an embedded process that never ran this loader -- which is the half-loaded
% case these needs cannot see.

title('Spaces on MORK''s Rust trie, over the FFI').
needs(artefact('mork_ffi/target/release/libmork_ffi.so')).
needs(artefact('mork_ffi/morklib.so')).
needs(predicate(open_shared_object/3)).
entry(engine, 'mork_ffi/morkspaces.pl').
