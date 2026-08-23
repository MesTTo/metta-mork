% Purpose: connect named MeTTa spaces to MORK through its text FFI protocol,
%   as a provider behind the engine's foreign-space seam.
% Assumes:
%   - the engine consults seam:foreign_space/1 before its own storage, and
%     its foreign match clause splits conjunctions per conjunct and answers
%     an unbound pattern through seam:foreign_atoms/2
%     [source: engine/spaces.pl, match_foreign/4]
% Guarantees:
%   - a MORK space refuses an unbound space name the way a native one does
%     [tested: spaces_storage_modules:matching_requires_a_named_space].
%   - a space this backend does not own leaves every ownership seam here by
%     FAILING, so the next provider's clause runs and no value is refused on
%     its behalf
%     [tested: test_a_query_joins_stored_atoms_with_live_object_fields].
% Open Obligations:
%   To Do: None
%   Hacks: None
%   Future Enhancements: None

%The seam, not the core predicates. Declaring match/4, 'add-atom'/3,
%'remove-atom'/3 and 'get-atoms'/2 multifile put MORK's clauses ahead of the
%engine's, because this file used to load before spaces.pl, so the engine's
%instantiation guards were unreachable whenever MORK was present. That is
%every shipping configuration on a machine that built the FFI, and it made
%(get-atoms $any) answer from MORK rather than refuse. lib_redis.pl and
%bindings/python/metta/shim.pl are behind this same seam.
%
%Load ORDER is no longer load-bearing either, which is the part worth
%checking rather than assuming: the seam dispatches on
%seam:foreign_space/1 rather than on clause position, so this file was moved
%AFTER spaces in engine/metta.pl's boot list and the whole gate, the fifteen MORK
%tests included, passes unchanged [verified 2026-08-16]. Before the port,
%precedence came from a position in an ensure_loaded list and nothing
%declared it.
:- multifile seam:foreign_space/1.
:- multifile seam:foreign_add/2.
:- multifile seam:foreign_add_many/2.
:- multifile seam:foreign_remove/3.
:- multifile seam:foreign_atoms/2.
:- multifile seam:foreign_match/3.
:- multifile seam:foreign_capability/2.
:- multifile seam:foreign_plan/5.

%MORK spaces address from MeTTa as &mork (the default space) or
%&mork:<name>, each name its own store inside MORK, created on first
%use. A request to a named space rides a "#mork-space <name>" header;
%the default space sends the bare payload, which keeps the original
%wire protocol unchanged.
%
%The name is an input. Matching an unbound argument against '&mork' would
%bind it, which is how an unnamed space used to become MORK's default one.
mork_space_name(Space, "default") :- Space == '&mork', !.
mork_space_name(Space, Name) :- atom(Space),
                                atom_concat('&mork:', RawName, Space),
                                RawName \== '',
                                !,
                                atom_string(RawName, Name).

mork_call(Space, Command, Payload, Response) :-
    %A NUL byte truncates at the C boundary mid-form and MORK's loader
    %panics on the resulting UnexpectedEOF, killing the process. Refuse
    %it loudly here, the one choke point every command crosses.
    ( string(Payload), string_code(_, Payload, 0)
      -> throw(error(domain_error(mork_text, Payload),
                     context(mork_call/4,
                             'a NUL byte cannot cross the MORK boundary')))
    ; true ),
    mork_space_name(Space, Name),
    ( Name == "default"
      -> Request = Payload
    ; format(string(Request), "#mork-space ~w~n~w", [Name, Payload]) ),
    mork(Command, Request, Response).

%MORK's bridge consumes swrite text. A value whose printed form does not read
%back as itself cannot retain its identity there, and the grammar owns that
%rule: MeTTa has no quoted-symbol syntax, so a name with a delimiter or a quote
%in it loses its identity, and it has no literal for a non-finite float or a
%rational either, so 1.0Inf, 1.5NaN and 1r3 come back as symbols. Asking is
%metta_unwritable_symbol/2, one of the four text services the engine publishes
%for exactly this [source: engine/ext_points.pl, "Services a backend may call"].
%It was wrapped here under a private name until those were declared, which is
%what an undeclared dependency looks like from the outside.
mork_require_text_safe(Term, Operation) :-
    ( metta_unwritable_symbol(Term, Bad)
      -> throw(error(domain_error(mork_text_symbol, Bad),
                     context(Operation,
                             'symbol names containing whitespace, parentheses or quotes, and numbers whose printed form is not read back as the same number, cannot cross the MORK text boundary')))
    ; true ).

%Whether a request is this backend's at all. Every ownership seam below opens
%with it, which is what an ownership seam asks of a provider: "every provider
%in this tree writes ONE clause with a variable space and an ownership guard in
%the body, which unifies with any space at all"
%[source: engine/ext_points.pl, the seam:foreign_capability/2 note].
%
%It was spelled out twice and MISSING from the four seams that touch the
%provider, which left the ownership test to mork_call/4 further down each body.
%That is too late: seam:foreign_match/3 and seam:foreign_add/2 ask
%mork_require_text_safe/2 FIRST, and that refuses rather than fails. MORK's
%clauses come first in every one of these multifile predicates, so a value with
%no MeTTa text spelling reaching any OTHER provider's space got MORK's domain
%error and that provider's clause was never tried. It stayed invisible while
%metta_unwritable_symbol/2 answered no for an opaque host value; the walk in
%engine/parser.pl answers yes for one now, so a Python object_view's Box in a
%pattern was refused by a backend with no claim on it.
%
%Every MORK space name starts with &mork, and the engine asks this question
%on every write and every match, native spaces included. One prefix test
%rejects every other space before the name is parsed: parsing first cost 400
%inferences over register-op's registrations and 5 over a five-way join
%[measured 2026-08-15].
mork_owns_space(Space) :- atom(Space),
                          sub_atom(Space, 0, 5, _, '&mork'),
                          mork_space_name(Space, _).

%A MORK space is a foreign space: its atoms live outside the Prolog
%database and this file owns every read and write of them.
seam:foreign_space(Space) :- mork_owns_space(Space).

%Four of the five, declared. MORK has no clear, and saying so is what turns
%(clear &mork) from a silent nothing into a refusal that names the space and
%the operation. The same ownership test guards this as guards the space
%itself, so an unrelated space costs one sub_atom/5 to reject.
%rules is declared because MORK holds whatever atoms it is given, EQUATIONS
%included. That is the whole of what the capability asks: the engine compiles
%an equation added to this space and MORK stores the atom, so a rule here is
%the same compiled clause a native one is. Without the declaration an equation
%would be refused, and before the capability existed it was stored and inert.
%
%What it does NOT cover is an equation that reaches MORK another way, an
%mm2-exec write or MORK's own loader: the engine is told about an add, so an
%equation nothing added is stored and inert.
seam:foreign_capability(Space, Capability) :-
    mork_owns_space(Space),
    member(Capability, [add, remove, match, enumerate, rules, plan]).

%What a MORK space's change events promise. at-most-once, and the reason is
%the paragraph above: an add THROUGH the engine fires the write hooks, so a
%watcher hears it exactly once and in write order, and an mm2-exec write or
%MORK's own loader reaches the store without the engine being told, so that
%change reaches no watcher at all. Some writes are delivered and none is
%delivered twice is exactly at-most-once, and ordered is honest because the
%deliveries that do happen are synchronous inside their own write.
%
%The seam rather than an (events &mork ...) atom because a MORK space is
%every name beginning &mork, so there is no one name to write the atom
%about; mork_owns_space/1 is the same one-prefix test that guards the rest
%of this file [P12.14].
:- multifile seam:context_events/3.
seam:context_events(Space, 'at-most-once', ordered) :-
    mork_owns_space(Space).

%Add an atom to the space. The engine fires the write hooks around
%metta_add_atom/3, so subscriptions and reflection see MORK writes too:
seam:foreign_add(Space, Atom) :- mork_owns_space(Space),
                                  mork_require_text_safe(Atom, 'add-atom'/3),
                                  swrite(Atom, S),
                                  mork_call(Space, "queue-atom", S, "OK: queued").

%Add a whole list of atoms in ONE crossing: the payload joins their
%text and MORK parses it as a batch, so ingestion pays one FFI call
%and one lock instead of one per atom. Hooks still fire per atom.
'mork-add-atoms'(Space, Atoms, true) :-
    mork_space_name(Space, _),
    is_list(Atoms),
    maplist(mork_require_text_safe_for_add, Atoms),
    maplist(swrite, Atoms, Lines),
    atomics_to_string(Lines, "\n", Payload),
    mork_call(Space, "add-atoms", Payload, "OK: loaded"),
    forall(member(Atom, Atoms),
           forall(seam:atom_added(Space, Atom), true)).

mork_require_text_safe_for_add(Atom) :-
    mork_require_text_safe(Atom, 'mork-add-atoms'/3).

%The engine's batch seam, answered with the same crossing. It routes only atoms
%whose add is a store and nothing more through here, so a batch that reaches
%MORK has nothing for the per-atom path to have done differently.
seam:foreign_add_many(Space, Atoms) :- 'mork-add-atoms'(Space, Atoms, true).

%MORK answers every removal with "OK: loaded" and no count, so whether
%anything was there is a separate question, and it is asked through MORK's
%own matching rather than a dump of the space. Answering true unconditionally
%would report a removal that did not happen.
%
%The seam's "remove one" and MORK's remove-atoms coincide here because MORK
%is a SET on the way in: three adds of (dup 1) leave one atom and a count of
%1 [measured 2026-08-19], so there is never a second copy for a sweep to take.
%That is a divergence from the multiset a space is meant to be, and it is on
%the ADD side rather than this one.
seam:foreign_remove(Space, Atom, Removed) :-
    mork_owns_space(Space),
    ( mork_holds(Space, Atom) -> Removed = true ; Removed = false ),
    mork_require_text_safe(Atom, 'remove-atom'/3),
    swrite(Atom, S),
    mork_call(Space, "remove-atoms", S, _).

%Whether the space holds anything this atom unifies with. An unbound atom
%asks whether the space holds anything at all, which is what match/4 does
%with one [source: engine/spaces.pl, match_foreign/4].
mork_holds(Space, Atom) :-
    \+ \+ ( var(Atom)
            -> seam:foreign_atoms(Space, Atom)
            ;  seam:foreign_match(Space, Atom, []) ).

%Match one pattern, MORK's own matching rather than a scan. The engine
%hands over one non-conjunctive, bound pattern at a time: it splits a
%conjunction per conjunct and answers an unbound pattern through
%seam:foreign_atoms/2, so joins over this space are the engine's joins,
%each conjunct answered by MORK.
seam:foreign_match(Space, Pattern, _Options) :- mork_owns_space(Space),
                                       Pattern_Template = [Pattern, Pattern],
                                       mork_require_text_safe(Pattern_Template, match/4),
                                       swrite(Pattern_Template, MorkPat),
                                       mork_call(Space, "match", MorkPat, Temp),
                                       mork_response_term(Temp, MatchedPattern),
                                       Pattern = MatchedPattern.

%MORK's own worst-case-optimal join, claimed WHOLE.
%
%The engine splits a conjunction one pattern at a time and re-dispatches the
%next on every binding of the previous, which is a nested-loop plan. MORK's
%query_multi is worst-case-optimal over the whole conjunction, so a partial
%claim would hand the interesting half back as a nested loop; there is no shape
%of conjunction where taking part of it beats taking all of it here.
%
%It declines rather than throws for anything it cannot express, which is what
%the seam asks of a claim: an atom whose symbols do not survive MORK's text
%boundary, or a conjunct that is not a written pattern. Declining costs the
%caller the ordinary split and nothing else.
seam:foreign_plan(Space, Conjuncts, Conjuncts, [], mork_query_multi(Space, Conjuncts)) :-
    mork_space_name(Space, _),
    forall(member(Conjunct, Conjuncts), mork_plannable_pattern(Conjunct)).

%A pattern MORK can be asked for: written, not a bare variable, and every
%symbol in it round-trips through the text boundary. It asks
%metta_unwritable_symbol/2 directly rather than mork_require_text_safe/2,
%because a claim DECLINES what it cannot express where a write refuses it: the
%caller gets the ordinary split and a correct answer either way.
mork_plannable_pattern(Conjunct) :- nonvar(Conjunct),
                                    Conjunct = [_|_],
                                    \+ metta_unwritable_symbol(Conjunct, _).

%The claim, answered. One crossing for the whole join, and the row carries the
%conjunction's variables in term_variables order, which is stable for the same
%term on both sides of the call.
mork_query_multi(Space, Conjuncts) :-
    term_variables(Conjuncts, Vars),
    Row = ['petta-join-row'|Vars],
    swrite([[','|Conjuncts], Row], Payload),
    mork_call(Space, "query-multi", Payload, Response),
    mork_response_term(Response, Answer),
    Answer = ['petta-join-row'|Values],
    Vars = Values.

%Get all atoms in space, irregard of arity:
seam:foreign_atoms(Space, Pattern) :- mork_owns_space(Space),
                                       mork_call(Space, "get-atoms", "", Temp),
                                       mork_response_term(Temp, Pattern).

%A response is one atom per line, with a trailing newline to skip.
mork_response_term(Response, Term) :- split_string(Response, "\n", "", Lines),
                                      member(Line, Lines),
                                      Line \== "",
                                      sread(Line, Term).

%Execute MM2 calculus
'mm2-exec'(Space, Steps, true) :- mork_space_name(Space, _),
                                  number_string(Steps, St),
                                  mork_call(Space, "mm2-exec", St, _).

%Make queued additions visible without performing another operation.
'mork-flush'(Space, true) :- mork_space_name(Space, _), !,
                             mork_call(Space, "flush", "", "OK: flushed").

%Init MORK. Both libraries resolve relative to THIS file, so the same
%init serves every load flow: the engine's startup branch, git-import!,
%and an embedded process without LD_PRELOAD. The Rust cdylib opens with
%global symbol visibility first, which is what lets morklib.so's
%undefined rust_mork references link when no LD_PRELOAD preceded us; a
%process that did preload merely reopens an already-mapped library.
%Failure throws: this file only loads when MORK was asked for.
:- prolog_load_context(directory, Dir),
   directory_file_path(Dir, 'target/release/libmork_ffi.so', RustLib),
   ( exists_file(RustLib) -> true
   ; throw(error(existence_error(mork_rust_library, RustLib),
                 context(RustLib, 'build mork_ffi first: sh build.sh'))) ),
   open_shared_object(RustLib, _, [global]),
   directory_file_path(Dir, 'morklib.so', ShimLib),
   ( exists_file(ShimLib) -> true
   ; throw(error(existence_error(mork_shim_library, ShimLib),
                 context(ShimLib, 'build mork_ffi first: sh build.sh'))) ),
   use_foreign_library(ShimLib),
   %Success is silent: every embedded boot and CLI run passes here, and
   %programs comparing process output must not carry a banner. Failure
   %throws, which is where the diagnostic value lives.
   ( current_predicate(mork/3) -> true
   ; throw(error(existence_error(procedure, mork/3),
                 context(ShimLib, 'mork/3 did not register on load'))) ).

%The builtins this bridge provides, named where they are defined. The engine
%registers whatever is declared and knows none of these names; they exist only
%when this file loads, which is the condition it would otherwise have to test.
:- multifile seam:backend_builtin/1.
seam:backend_builtin('mm2-exec').
seam:backend_builtin('mork-add-atoms').
seam:backend_builtin('mork-flush').

%This backend's smoke test, run by the CLI demo. It was mork_test/0 called by
%name from engine/main.pl, which is why that file had a `mork` branch at all.
:- multifile seam:backend_selftest/0.
%add-atom answers unit ([]), the arbiter's doctrine; demanding the old true
%made this fail silently inside the demo's forall from the day that changed.
seam:backend_selftest :-
    'add-atom'('&mork', [friend,sam,tim], []),
    'add-atom'('&mork', [friend,sam,joe], []),
    findall(C, match('&mork', [friend,sam,X], [friend,sam,X], C), Cs),
    format(string(SC), "MORK query result: ~w ~n", [Cs]),
    writeln(SC).
