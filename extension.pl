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
% The half-built case still raises: these needs met, morkspaces.pl loads, and
% it refuses to be half loaded however it was reached, including git-import!
% and an embedded process that never ran this loader.

title('Spaces on MORK''s Rust trie, over the FFI').
needs(artefact('mork_ffi/target/release/libmork_ffi.so')).
needs(predicate(open_shared_object/3)).
entry(engine, 'mork_ffi/morkspaces.pl').
