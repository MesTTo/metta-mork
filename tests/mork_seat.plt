% Purpose: this seat's own tests -- the three builtins it declares, the claim
%   it takes over the &mork namespace, and the failure discipline that lets the
%   next provider's clause run for a space it does not own.
% Assumes:
%   - loaded with the `extensions` token in argv, which is what makes the
%     engine read extensions/mork/extension.pl at all; a tokenless boot is the
%     pure kernel and every test here is skipped by seat_is_loaded/0
%     [source: engine/metta.pl, the metta_load_extensions/1 directive].
%   - a tree where `sh extensions/mork/build.sh` has run. Without the artefacts
%     the seat is absent and the built half below does not run; what runs
%     instead is extensions/mork/tests/test_missing_artefacts.sh, which boots a
%     real engine over a seat pointed at an absent artefact. Skipping is not
%     silent: extensions/mork/test.sh reads the count off this file and fails a
%     built tree that reported fewer.
% Guarantees:
%   - the three declared builtins are registered under the effect classes the
%     seat declares, so a world that covers writesState may run the two writes
%     and mm2-exec keeps the reviewed oracleIO
%     [tested: the_three_declared_builtins_are_registered_with_their_classes].
%   - the batch door lands every atom in one crossing, fires the write seam per
%     atom, and refuses an unwritable symbol, an over-wide expression and a NUL
%     byte BEFORE any of the batch is written
%     [tested: a_batch_add_lands_every_atom, a_batch_add_fires_the_write_seam_per_atom,
%     a_batch_add_refuses_an_unwritable_symbol_before_any_write,
%     a_batch_add_refuses_an_expression_beyond_morks_arity_encoding,
%     a_batch_add_refuses_a_nul_byte_at_the_boundary].
%   - a space this seat does not own leaves every ownership seam AND every
%     builtin by failing rather than refusing
%     [tested: a_space_the_seat_does_not_own_fails_every_seam,
%     a_space_the_seat_does_not_own_fails_every_builtin].
% Open Obligations:
%   To Do: None
%   Hacks: None
%   Future Enhancements: None

:- ensure_loaded('../../../engine/qlf_boot.pl').
:- ensure_loaded('../../../engine/metta.pl').

:- begin_tests(mork_seat).

%Whether the seat is here at all. Every test below carries it as a condition,
%so an unbuilt tree reports skips rather than failures: not built is not an
%error, and it is the same answer extension.pl's needs/1 gives.
seat_is_loaded :- metta_extension_loaded(mork).

%The backend needs BOTH shared objects: morkspaces.pl opens libmork_ffi.so for
%its global symbols and then use_foreign_library's morklib.so for mork/3
%itself. Both are declared needs now, so a tree carrying one of them answers
%exactly as an unbuilt tree does.
mork_artefacts_present :-
    forall(member(Relative, ['mork_ffi/target/release/libmork_ffi.so',
                             'mork_ffi/morklib.so']),
           ( metta_extension_seat_file(mork, Relative, Path, _),
             exists_file(Path) )).

%The two tests here that run in every configuration, including the tokenless
%pure kernel, because both of them ask a conditional that an absent seat
%answers no.
%
%This one is the net under every `condition(seat_is_loaded)` below. A recorded
%seat whose backend is not actually there makes each of those conditions read
%TRUE and each test raise, or -- if the raising ones were ever conditioned away
%-- skip in silence. It is not hypothetical: a load-time directive that throws
%is PRINTED by SWI and the consult carries on, so ensure_loaded/1 succeeds and
%metta_load_extension/1 records the seat, which is what a tree with
%libmork_ffi.so and no morklib.so used to do on every boot.
test(a_recorded_seat_has_a_working_backend_behind_it) :-
    (   metta_extension_loaded(mork)
    ->  assertion(current_predicate(mork/3))
    ;   true
    ).

%And the other direction: where this boot read seats at all and both artefacts
%are on disk, the seat is loaded. A tokenless boot and an unbuilt tree both
%answer the antecedent no and pass; a tree that built the backend and then
%failed to reach it fails here rather than skipping every test below.
test(the_seat_loads_wherever_the_boot_reads_seats_and_both_artefacts_exist) :-
    current_prolog_flag(argv, Argv),
    (   memberchk(extensions, Argv),
        mork_artefacts_present
    ->  assertion(metta_extension_loaded(mork))
    ;   true
    ).

%A scratch space per test, named after the test, so no test reads another's
%store and a failure names its own space. Clearing is the seat's own
%foreign_clear, which removes through the ordinary funnel and then drops the
%Rust registry entry.
scratch(Name, Space) :- atom_concat('&mork:seat-test-', Name, Space).

drop(Space) :- catch(seam:foreign_clear(Space), _, true).

held(Space, Atoms) :-
    findall(Atom, seam:foreign_atoms(Space, Atom), Found),
    msort(Found, Atoms).

edges(Count, Rows) :-
    findall([edge, I, J], ( between(1, Count, I), J is I + 1 ), Rows).

%%%% What the seat declares %%%%

%The three names and their effect classes, read back through the engine's own
%registry rather than off the seat's facts: seam:extension_builtin/2 is a
%DECLARATION, and what matters is that registration.pl turned it into a
%builtin and effects.pl reads the declared class instead of the oracleIO floor.
test(the_three_declared_builtins_are_registered_with_their_classes,
     [condition(seat_is_loaded)]) :-
    forall(member(Name-Class, ['mork-add-atoms'-writesState,
                               'mork-flush'-writesState,
                               'mm2-exec'-oracleIO]),
           ( assertion(builtin_fun(Name)),
             assertion(seam:extension_builtin(Name, Class)),
             assertion(metta_builtin_effect(Name, Class)) )).

%Every storage capability the seat says it has. Read whole rather than one at a
%time, so a capability silently dropped from the list fails here.
test(the_seat_declares_every_storage_capability,
     [condition(seat_is_loaded)]) :-
    findall(Capability, seam:foreign_capability('&mork', Capability), Found),
    msort(Found, Sorted),
    assertion(Sorted == [add, clear, enumerate, match, plan, remove, rules]).

%What a MORK space promises a watcher, which the seat answers through the seam
%rather than through an (events ...) atom because every name beginning &mork is
%one space to this provider.
test(the_seat_declares_its_change_event_discipline,
     [condition(seat_is_loaded)]) :-
    findall(Delivery-Order,
            seam:context_events('&mork:seat-test-events', Delivery, Order),
            Found),
    assertion(Found == ['at-most-once'-ordered]).

%%%% mork-add-atoms, the batch door %%%%

test(a_batch_add_lands_every_atom,
     [condition(seat_is_loaded), setup(scratch(batch, S)), cleanup(drop(S))]) :-
    edges(200, Rows),
    'mork-add-atoms'(S, Rows, Answer),
    assertion(Answer == true),
    held(S, Held),
    msort(Rows, Wanted),
    assertion(Held == Wanted).

%The batch is ONE crossing and the per-atom path is many, and the door's
%promise is that the two land the same content. The oracle is the per-atom
%path itself over the same rows in a second space.
test(a_batch_add_lands_what_the_per_atom_door_lands,
     [ condition(seat_is_loaded),
       setup(( scratch('batch-one', One), scratch('batch-many', Many) )),
       cleanup(( drop(One), drop(Many) )) ]) :-
    edges(50, Rows),
    'mork-add-atoms'(One, Rows, true),
    forall(member(Row, Rows), 'add-atom'(Many, Row, _)),
    held(One, Batched),
    held(Many, PerAtom),
    assertion(Batched == PerAtom).

%The write seam fires once per atom, which is what keeps a subscription and
%anything else reading writes from missing a batch. seam:atom_added/2 is the
%engine's declared event point and the batch calls it per atom by hand, so a
%batch that stopped calling it would be invisible to every watcher.
:- dynamic mork_seat_test_saw/2.

test(a_batch_add_fires_the_write_seam_per_atom,
     [ condition(seat_is_loaded), setup(scratch(hooked, S)),
       cleanup(( drop(S),
                 retractall(user:mork_seat_test_saw(_, _)),
                 retractall(seam:atom_added(_, _)) )) ]) :-
    assertz((seam:atom_added(Space, Atom) :-
                 assertz(user:mork_seat_test_saw(Space, Atom)))),
    edges(5, Rows),
    'mork-add-atoms'(S, Rows, true),
    findall(Atom, user:mork_seat_test_saw(S, Atom), Seen),
    msort(Seen, Sorted),
    msort(Rows, Wanted),
    assertion(Sorted == Wanted),
    length(Seen, Count),
    assertion(Count == 5).

%A symbol whose printed form does not read back as itself cannot keep its
%identity across MORK's text boundary, and the batch checks the WHOLE list
%before it writes any of it: a half-written batch would leave the space in a
%state no caller asked for.
test(a_batch_add_refuses_an_unwritable_symbol_before_any_write,
     [ condition(seat_is_loaded), setup(scratch(unsafe, S)), cleanup(drop(S)),
       throws(error(domain_error(mork_text_symbol, 'bad name'), _)) ]) :-
    'mork-add-atoms'(S, [[safe, one], [holds, 'bad name']], _).

test(nothing_of_a_refused_batch_reached_the_store,
     [ condition(seat_is_loaded), setup(scratch(unsafe, S)), cleanup(drop(S)) ]) :-
    catch('mork-add-atoms'(S, [[safe, one], [holds, 'bad name']], _), _, true),
    held(S, Held),
    assertion(Held == []).

%MORK's byte tag carries a six-bit arity, and its parser ASSERTS rather than
%returning an error at 64, so the seat proves the shape before handing text to
%Rust. Sixty-three children pass; sixty-four abort the process without this.
test(a_batch_add_refuses_an_expression_beyond_morks_arity_encoding,
     [ condition(seat_is_loaded), setup(scratch(wide, S)), cleanup(drop(S)),
       throws(error(domain_error(mork_expression_width, _), _)) ]) :-
    length(Children, 64),
    maplist(=(x), Children),
    'mork-add-atoms'(S, [[wide|Children]], _).

test(a_batch_add_accepts_the_widest_expression_mork_encodes,
     [ condition(seat_is_loaded), setup(scratch('wide-ok', S)), cleanup(drop(S)) ]) :-
    length(Children, 62),
    maplist(=(x), Children),
    'mork-add-atoms'(S, [[wide|Children]], true),
    held(S, Held),
    assertion(Held == [[wide|Children]]).

%A NUL truncates at the C boundary mid-form and MORK's loader panics on the
%resulting UnexpectedEOF, killing the process. The one choke point every
%command crosses refuses it instead, and the batch reaches that choke point.
test(a_batch_add_refuses_a_nul_byte_at_the_boundary,
     [ condition(seat_is_loaded), setup(scratch(nul, S)), cleanup(drop(S)),
       throws(error(domain_error(mork_text, _), _)) ]) :-
    atom_codes(Text, [0'a, 0, 0'b]),
    atom_string(Text, Payload),
    'mork-add-atoms'(S, [[holds, Payload]], _).

%A batch whose second argument is not a list FAILS. That is the same guard the
%seam:foreign_add_many/2 implementation needs -- a space or a shape this
%provider cannot serve must fail so the next provider's clause runs -- and it
%is recorded here because a builtin that fails on a wrong-typed argument is a
%silent no-op to a MeTTa caller rather than a named refusal.
test(a_batch_add_of_a_non_list_fails_and_writes_nothing,
     [ condition(seat_is_loaded), setup(scratch(nonlist, S)), cleanup(drop(S)) ]) :-
    assertion(\+ 'mork-add-atoms'(S, not_a_list, _)),
    assertion(\+ 'mork-add-atoms'(S, _Unbound, _)),
    held(S, Held),
    assertion(Held == []).

%%%% mork-flush %%%%

%Writes queue inside MORK and a read flushes first, so what flush buys is
%making them visible WITHOUT performing another operation. Both halves are
%here: the atoms are there afterwards, and a second flush is not an error.
test(flush_publishes_queued_writes_and_answers_the_unit,
     [ condition(seat_is_loaded), setup(scratch(flush, S)), cleanup(drop(S)) ]) :-
    forall(between(1, 10, I), 'add-atom'(S, [queued, I], _)),
    'mork-flush'(S, Answer),
    assertion(Answer == true),
    held(S, Held),
    findall([queued, I], between(1, 10, I), Rows),
    msort(Rows, Wanted),
    assertion(Held == Wanted).

test(flush_is_idempotent,
     [ condition(seat_is_loaded), setup(scratch('flush-twice', S)), cleanup(drop(S)) ]) :-
    'add-atom'(S, [queued, one], _),
    'mork-flush'(S, true),
    'mork-flush'(S, true),
    held(S, Held),
    assertion(Held == [[queued, one]]).

%%%% mm2-exec %%%%

%The MM2 calculus runs inside the Rust library over rules held as DATA in the
%space, which is why the seat classes it oracleIO: what a call reaches is
%decided at run time by content the engine never sees. One step of one exec
%rule consumes the friend fact and produces the enemy one.
test(mm2_exec_runs_the_calculus_inside_mork,
     [ condition(seat_is_loaded), setup(scratch(mm2, S)), cleanup(drop(S)) ]) :-
    sread("(friend sam tim)", Fact),
    sread("(exec 0 (, (friend sam $x)) (O (- (friend sam $x)) (+ (enemy sam $x))))",
          Rule),
    'add-atom'(S, Fact, _),
    'add-atom'(S, Rule, _),
    'mm2-exec'(S, 1, Answer),
    assertion(Answer == true),
    held(S, Held),
    assertion(memberchk([enemy, sam, tim], Held)),
    assertion(\+ memberchk([friend, sam, tim], Held)).

%The step count is MORK's own budget and this seat passes it through verbatim,
%so the number a caller writes decides how far the calculus runs. A two-rule
%chain shows it: a sam -> b sam -> c sam, where 0 leaves the space one
%application in with the second rule still standing and 1 reaches the end of
%the chain with both rules consumed [measured 2026-08-28].
%
%What this deliberately does NOT assert is what MM2 means by a step: 0 is not
%"no steps" here, `s.space.metta_calculus(num)` is reached with whatever
%integer arrives [source: extensions/mork/mork_ffi/src/lib.rs, the mm2-exec
%command]. The pin is that the argument reaches the calculus and changes the
%result, which is this seat's half of the contract; MORK owns the other half
%and a change to it should turn this red rather than pass unnoticed.
test(the_step_count_reaches_morks_calculus,
     [ condition(seat_is_loaded),
       setup(( scratch('mm2-budget-0', Zero), scratch('mm2-budget-1', One) )),
       cleanup(( drop(Zero), drop(One) )) ]) :-
    forall(member(Space, [Zero, One]), mm2_chain(Space)),
    'mm2-exec'(Zero, 0, true),
    'mm2-exec'(One, 1, true),
    held(Zero, AfterZero),
    held(One, AfterOne),
    assertion(memberchk([b, sam], AfterZero)),
    assertion(AfterOne == [[c, sam]]).

%One fact and two exec rules that rewrite it along a chain.
mm2_chain(Space) :-
    sread("(a sam)", Fact),
    sread("(exec 0 (, (a $x)) (O (- (a $x)) (+ (b $x))))", First),
    sread("(exec 0 (, (b $x)) (O (- (b $x)) (+ (c $x))))", Second),
    forall(member(Atom, [Fact, First, Second]), 'add-atom'(Space, Atom, _)).

test(mm2_exec_over_a_space_with_no_exec_rules_changes_nothing,
     [ condition(seat_is_loaded), setup(scratch('mm2-inert', S)), cleanup(drop(S)) ]) :-
    'add-atom'(S, [plain, fact], _),
    held(S, Before),
    'mm2-exec'(S, 1, true),
    held(S, After),
    assertion(After == Before).

%%%% The claim over the namespace %%%%

%The seat takes the NAMESPACE at load, so `metta list` and any second provider
%read one table rather than discovering the collision by storing an atom in the
%wrong place.
test(the_seat_claims_the_mork_namespace, [condition(seat_is_loaded)]) :-
    assertion(metta_space_claim(prefix('&mork'), mork)).

test(another_owner_is_refused_a_name_inside_the_claim,
     [condition(seat_is_loaded)]) :-
    catch(( metta_claim_space('&mork:taken', mork_seat_test_probe), fail ),
          Error,
          message_to_string(Error, Text)),
    assertion(sub_string(Text, _, _, _, "mork_seat_test_probe cannot claim")),
    assertion(sub_string(Text, _, _, _, "&mork:taken")),
    assertion(sub_string(Text, _, _, _, "mork already claims")),
    assertion(sub_string(Text, _, _, _, "metta_disclaim_space")),
    assertion(\+ metta_space_claim('&mork:taken', mork_seat_test_probe)).

%The claim is WIDER than what the seat serves, and this records the gap rather
%than reading round it. `&morkfoo` begins with the claimed prefix, so no other
%provider may take it, and it parses as neither `&mork` nor `&mork:<name>`, so
%this seat answers nothing for it and it behaves as a native space.
%
%Limitation: the extent vocabulary is a name or prefix(P), and the served
%extent is "&mork, or &mork: followed by something", which neither shape spells
%and no pair of them spells either -- prefix('&mork:') plus '&mork' would still
%claim the bare `&mork:`, which is equally unserved. So the over-approximation
%is the extent language's rather than this seat's, and narrowing it would trade
%one unusable name for another [source: engine/spaces/foreign.pl,
%metta_space_extents_meet/2].
test(a_name_the_claim_covers_but_the_seat_does_not_serve,
     [condition(seat_is_loaded)]) :-
    assertion(\+ seam:foreign_space('&morkfoo')),
    catch(( metta_claim_space('&morkfoo', mork_seat_test_probe), fail ),
          Error,
          message_to_string(Error, Text)),
    assertion(sub_string(Text, _, _, _, "mork already claims")).

%%%% Failing rather than refusing, for a space this seat does not own %%%%

%Every ownership seam opens with the same one-prefix test, and what it must do
%for somebody else's space is FAIL. Refusing would be worse than wrong: MORK's
%clauses come first in each of these multifile predicates, so a refusal here
%would reach the caller instead of the next provider's clause, and a value with
%no MeTTa text spelling would be refused by a backend with no claim on it.
%
%Both a native name and a name inside the claim that the seat does not serve,
%because those are two different reasons to fail and one clause answers both.
test(a_space_the_seat_does_not_own_fails_every_seam,
     [condition(seat_is_loaded)]) :-
    forall(member(Space, ['&self', '&morkfoo', '&metta-space-1']),
           ( assertion(\+ seam:foreign_space(Space)),
             assertion(\+ seam:foreign_add(Space, [probe])),
             assertion(\+ seam:foreign_add_many(Space, [[probe]])),
             assertion(\+ seam:foreign_remove(Space, [probe], _)),
             assertion(\+ seam:foreign_atoms(Space, _)),
             assertion(\+ seam:foreign_match(Space, [probe, _], [])),
             assertion(\+ seam:foreign_capability(Space, add)),
             assertion(\+ seam:foreign_plan(Space, [[probe, _]], _, _, _)),
             assertion(\+ seam:foreign_clear(Space)),
             assertion(\+ seam:context_events(Space, _, _)) )).

test(a_space_the_seat_does_not_own_fails_every_builtin,
     [condition(seat_is_loaded)]) :-
    forall(member(Space, ['&self', '&morkfoo']),
           ( assertion(\+ 'mork-add-atoms'(Space, [[probe]], _)),
             assertion(\+ 'mork-flush'(Space, _)),
             assertion(\+ 'mm2-exec'(Space, 1, _)) )).

%A space the seat DOES own answers each of the same seams, so the test above
%is discriminating rather than vacuous: without this, a seat whose every clause
%had been deleted would pass it.
test(a_space_the_seat_owns_answers_the_same_seams,
     [ condition(seat_is_loaded), setup(scratch(owned, S)), cleanup(drop(S)) ]) :-
    assertion(seam:foreign_space(S)),
    assertion(seam:foreign_capability(S, add)),
    assertion(seam:context_events(S, _, _)),
    assertion(seam:foreign_add_many(S, [[probe, one]])),
    assertion(seam:foreign_match(S, [probe, _], [])),
    assertion(seam:foreign_remove(S, [probe, one], true)),
    assertion(seam:foreign_clear(S)).

:- end_tests(mork_seat).
