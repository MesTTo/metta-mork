% Purpose: tell the engine where the MORK backend lives and when it is usable.
%   This file is the whole of what the engine knows about MORK, and it is not
%   in the engine.
% Assumes:
%   - mork_ffi/target/release/libmork_ffi.so beside this file is what `sh build.sh` produces,
%     and its absence means the backend was not built rather than that anything
%     is wrong [tested: the suites run in both configurations]
% Guarantees:
%   - a tree without the build artefact loads this file and nothing happens
%   - a tree with it loads the mork_ffi/morkspaces.pl beside it, which raises if any part of
%     the build is missing or the foreign predicate does not register
% Fails when:
%   - the artefact exists but is broken. That raises rather than being skipped,
%     which is the split a host wants and should not have to implement: not
%     built is not an error, half built is.
% Open Obligations:
%   To Do: None
%   Hacks: None
%   Future Enhancements: None

%The check is here and the throw is in morkspaces.pl, and they answer different
%questions. This one asks "was this backend built", which decides whether the
%engine loads it at all. That one asks "can I run", and refuses to be half
%loaded however it was reached, including the git-import! flow and an embedded
%process that never consulted this file.
%The artefact's PRESENCE is not enough on a platform that cannot open a shared
%object at all. A WebAssembly build mounts this checkout's files, so the .so is
%there to be seen and open_shared_object/3 does not exist to open it; the
%backend then raised two ERROR lines through every boot of the Node binding,
%which its old stderr parser matched neither of and absorbed in silence. That
%is not the half-built case this file refuses to skip: the build is fine and
%the platform has no dynamic linking, so the honest answer is the same as an
%unbuilt tree's.
:- prolog_load_context(directory, Dir),
   directory_file_path(Dir, 'mork_ffi/target/release/libmork_ffi.so', Artefact),
   (   exists_file(Artefact),
       current_predicate(open_shared_object/3)
   ->  directory_file_path(Dir, 'mork_ffi/morkspaces.pl', Backend),
       ensure_loaded(Backend)
   ;   true
   ).
