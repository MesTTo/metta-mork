% Purpose: one benchmark workload per process, so extensions/mork/bench.sh can
%   measure this backend's crossings with perf.
% Assumes:
%   - argv carries `extensions <case> <size> <phase>`; the engine reads the
%     seats only when the first of those is there
%     [source: engine/metta.pl, the metta_load_extensions/1 directive].
%   - the backend is built. A run whose seat is absent halts nonzero rather
%     than measuring a boot.
%   - in the `window` phase, perf's control and acknowledgement pipes arrive as
%     METTA_PERF_CONTROL_FD and METTA_PERF_ACK_FD
%     [source: extensions/python/metta/benchmarking.py, measure_instructions'
%     controlled=True branch].
% Guarantees:
%   - the setup is OUTSIDE the measured region and the operation is inside it,
%     so what a sample counts is the operation. Whole-process subtraction was
%     tried first and is not usable at this resolution: the same difference
%     read +1,592,533 under an inherited environment, +774,281 under LC_ALL=C
%     and -714,626 under LC_ALL=C.UTF-8, three stable modes selected by the
%     environment block rather than by any work [measured 2026-08-28, the flush
%     case at 500]. Under the window the same operation reads within 0.018%
%     across separate invocations.
%   - there is no teardown in the measured region: the process exit is the
%     teardown, and seam:foreign_clear/1 removes atoms ONE AT A TIME, which
%     measured 13x the cost of every workload here when it sat inside
%     [measured 2026-08-28].
%   - a MORK read case flushes in SETUP, so the pending-write flush a read
%     performs implicitly is not charged to the read and the MORK and native
%     sides of a comparison are asked the same question
%     [source: extensions/mork/mork_ffi/src/lib.rs, flush_pending_atoms before
%     each read command].
%   - every operation answers a count and the count is checked, so a case that
%     silently wrote or matched nothing halts nonzero instead of measuring an
%     empty window [tested: extensions/mork/benchmarks/bench.py, run by
%     extensions/mork/bench.sh].
% Owns resources:
%   - the two /dev/fd streams the window opens, closed by setup_call_cleanup/3
%     whether the operation succeeds, fails or throws. The inherited descriptors
%     THEMSELVES are not closed: SWI has no raw close, opening /dev/fd/N makes a
%     new description rather than adopting the old one, and perf holds its own
%     ends, so the duplicates cost nothing until the process exits.
% Decides:
%   - the native side of every comparison is a plain named space, which is what
%     a program gets when no provider claims the name.
% Open Obligations:
%   To Do: None
%   Hacks: None
%   Future Enhancements: None

:- ensure_loaded('../../../engine/metta.pl').

%The rows every case works over: a path graph, so an open match answers Size
%rows and a bound one answers exactly one whatever Size is.
bench_rows(Size, Rows) :-
    findall([edge, I, J], ( between(1, Size, I), J is I + 1 ), Rows).

%A J that exists in the graph, so the bound match answers one row at any size.
bench_probe(Size, Probe) :- Probe is Size // 2 + 1.

%A space per case and size, so no two cases share a store. A native name must
%not begin &mork or this seat's claim would take it.
mork_space(Case, Size, Space) :-
    atomic_list_concat(['&mork:bench-', Case, '-', Size], Space).
native_space(Case, Size, Space) :-
    atomic_list_concat(['&native-bench-', Case, '-', Size], Space).

%%%% The cases %%%%
%
%bench_case(Case, Size, Setup, Operation, Count, Expected): Setup runs in both
%phases and Operation only in `full`. Operation binds Count, which must come
%out Expected.

bench_case('batch-add', Size, bench_rows(Size, Rows),
           bench_batch(Space, Rows, Count), Count, Size) :-
    mork_space('batch-add', Size, Space).

bench_case('per-atom-add', Size, bench_rows(Size, Rows),
           bench_one_by_one(Space, Rows, Count), Count, Size) :-
    mork_space('per-atom-add', Size, Space).

bench_case('native-add', Size, bench_rows(Size, Rows),
           bench_one_by_one(Space, Rows, Count), Count, Size) :-
    native_space('native-add', Size, Space).

%Two selective queries rather than one, because which POSITION is bound is the
%whole question for a trie. MORK stores an atom as a path, so a bound FIRST
%argument is a prefix it can descend to and a bound LAST argument is a
%constraint it can only check after walking, which is the difference between an
%index and a scan. Asking only one of them would report a backend's best or
%worst case as if it were its behaviour.
bench_case('mork-match-first', Size,
           ( bench_fill_mork(Space, Size),
             bench_count(Space, [edge, Probe, _], _) ),
           bench_queries(Space, [edge, Probe, _], Count), Count, Queries) :-
    mork_space('mork-match-first', Size, Space),
    bench_probe(Size, Probe),
    bench_queries(Queries).

bench_case('native-match-first', Size,
           ( bench_fill_native(Space, Size),
             bench_count(Space, [edge, Probe, _], _) ),
           bench_queries(Space, [edge, Probe, _], Count), Count, Queries) :-
    native_space('native-match-first', Size, Space),
    bench_probe(Size, Probe),
    bench_queries(Queries).

bench_case('mork-match-last', Size,
           ( bench_fill_mork(Space, Size),
             bench_count(Space, [edge, _, Probe], _) ),
           bench_queries(Space, [edge, _, Probe], Count), Count, Queries) :-
    mork_space('mork-match-last', Size, Space),
    bench_probe(Size, Probe),
    bench_queries(Queries).

bench_case('native-match-last', Size,
           ( bench_fill_native(Space, Size),
             bench_count(Space, [edge, _, Probe], _) ),
           bench_queries(Space, [edge, _, Probe], Count), Count, Queries) :-
    native_space('native-match-last', Size, Space),
    bench_probe(Size, Probe),
    bench_queries(Queries).

bench_case('mork-match-open', Size,
           ( bench_fill_mork(Space, Size),
             bench_count(Space, [edge, _, _], _) ),
           bench_count(Space, [edge, _, _], Count), Count, Size) :-
    mork_space('mork-match-open', Size, Space).

bench_case('native-match-open', Size,
           ( bench_fill_native(Space, Size),
             bench_count(Space, [edge, _, _], _) ),
           bench_count(Space, [edge, _, _], Count), Count, Size) :-
    native_space('native-match-open', Size, Space).

%Flush is the one case whose setup must NOT flush: what it measures is the cost
%of publishing writes that are still queued.
bench_case(flush, Size, bench_queue(Space, Size),
           bench_flush(Space, Count), Count, 1) :-
    mork_space(flush, Size, Space).

%What the measured region costs when the operation does nothing: the `disable`
%command's write and acknowledgement, which are inside it because counting is
%still on while they run. Every other row carries this, so it is measured
%rather than assumed, and a row near it is a row that is mostly floor.
bench_case('window-floor', _, true, bench_nothing(Count), Count, 1).

%%%% What the cases are made of %%%%

bench_batch(Space, Rows, Count) :-
    'mork-add-atoms'(Space, Rows, true),
    length(Rows, Count).

bench_one_by_one(Space, Rows, Count) :-
    aggregate_all(count,
                  ( member(Row, Rows), 'add-atom'(Space, Row, _) ),
                  Count).

%One query, answered and counted. Both sides of every comparison run this, so
%what is compared is the same question over the same rows.
%
%Every read case runs it ONCE in setup as well, which is what makes the window
%a steady-state measurement rather than a first-call one. It matters on the
%native side: SWI builds a clause index just in time, on the first call that
%would use one, and that build landed inside the window. native-match-bound at
%8000 then read [11414438, 11668824, 11634624] -- 2.23% apart within one run
%and 2.05% between runs, where every other row moved by under 0.05%
%[measured 2026-08-28]. Warming both sides keeps the comparison symmetrical.
bench_count(Space, Pattern, Count) :-
    aggregate_all(count, match(Space, Pattern, Pattern, _), Count).

%A selective query answers ONE row, and one of those is too small to measure
%against the window's own handshake: native-match-first at 8000 read 12,527
%instructions against a 29,068 floor, and one sample in three landed 23% below
%the other two [measured 2026-08-28]. A hundred of them is far above the floor
%and is the same question asked a hundred times, so what a row reports is the
%cost of ONE query and the noise divides by a hundred with it.
bench_queries(100).

bench_queries(Space, Pattern, Times) :-
    bench_queries(Times),
    forall(between(1, Times, _), bench_count(Space, Pattern, 1)).

bench_flush(Space, 1) :- 'mork-flush'(Space, true).

bench_nothing(1).

%A MORK space filled and flushed, so a read case measures the read. The batch
%door fills it because that is the door a program loading data uses; what the
%per-atom door costs is its own case above.
bench_fill_mork(Space, Size) :-
    bench_rows(Size, Rows),
    'mork-add-atoms'(Space, Rows, true),
    'mork-flush'(Space, true).

bench_fill_native(Space, Size) :-
    bench_rows(Size, Rows),
    forall(member(Row, Rows), 'add-atom'(Space, Row, _)).

bench_queue(Space, Size) :-
    forall(between(1, Size, I), 'add-atom'(Space, [queued, I], _)).

%%%% perf's measured region %%%%
%
%perf counts nothing until it is told to, when it is started with --delay=-1
%and a control pipe. The parent passes the two descriptor numbers in the
%environment; this writes `enable` before the operation and `disable` after,
%waiting for perf's acknowledgement each time so the boundary is where it says
%it is rather than wherever the write happened to land.
%
%The pipes are reached as /dev/fd/N because SWI has no door onto an inherited
%descriptor. On Linux that opens a new description on the same pipe, which is
%all a write and a read need.
%
%What is inside the region besides the operation: the `disable` command's own
%write and its acknowledgement, because counting is still on while they run.
%That is a constant per window and it is measured rather than assumed --
%bench.py's `window-floor` case runs this around an operation that does
%nothing, and every other case is read against it.
bench_window(Goal) :-
    getenv('METTA_PERF_CONTROL_FD', ControlText),
    getenv('METTA_PERF_ACK_FD', AckText),
    atom_number(ControlText, Control),
    atom_number(AckText, Ack),
    format(atom(ControlPath), '/dev/fd/~d', [Control]),
    format(atom(AckPath), '/dev/fd/~d', [Ack]),
    bench_warm,
    setup_call_cleanup(
        ( open(ControlPath, write, Out, [type(binary), buffer(false)]),
          open(AckPath, read, In, [type(binary)]),
          %A bound on the handshake, because without one a perf that never
          %armed leaves this process blocked until the driver's own deadline
          %kills it a minute later, and the driver cannot say why. perf can
          %fail to open the counter while another session holds the PMU, and
          %it acknowledges nothing when it does. Ten seconds is four orders of
          %magnitude above what the handshake costs when perf is there.
          set_stream(In, timeout(10)) ),
        ( bench_perf(Out, In, "enable"),
          call(Goal),
          bench_perf(Out, In, "disable") ),
        ( close(Out), close(In) )).

%Everything the window will call, called once before it opens. A predicate's
%FIRST call can autoload the library it lives in, and that load lands inside
%the measured region: read_line_to_codes/2 did exactly that and put 1,544,926
%instructions into an empty window, thirty times what the handshake costs
%without it [measured 2026-08-28]. The read side is written with get_byte/2
%for the same reason -- it is a builtin and nothing has to be found for it.
bench_warm :-
    setup_call_cleanup(open('/dev/null', write, Warm, [type(binary), buffer(false)]),
                       bench_send(Warm, "warm"),
                       close(Warm)),
    setup_call_cleanup(open('/dev/null', read, Empty, [type(binary)]),
                       catch(bench_acknowledge(Empty), _, true),
                       close(Empty)).

bench_perf(Out, In, Command) :-
    bench_send(Out, Command),
    bench_acknowledge(In).

bench_send(Out, Command) :-
    string_codes(Command, Codes),
    bench_put(Codes, Out),
    put_byte(Out, 0'\n),
    flush_output(Out).

bench_put([], _).
bench_put([Code|Rest], Out) :- put_byte(Out, Code), bench_put(Rest, Out).

%perf answers `ack\n`, and writes the tag's terminating NUL with it, so a
%leftover byte is normal and is consumed by the next read. Read to the newline
%a byte at a time, because that is the shape with no library behind it.
%[source: torvalds/linux tools/perf/util/evlist.h defines
%EVLIST_CTL_CMD_ACK_TAG as "ack\n" and tools/perf/util/evlist.c writes
%sizeof(EVLIST_CTL_CMD_ACK_TAG), which is five bytes.]
bench_acknowledge(In) :-
    catch(get_byte(In, Byte), Error, bench_no_acknowledgement(Error)),
    (   Byte =:= 0'\n
    ->  true
    ;   Byte =:= -1
    ->  bench_no_acknowledgement(end_of_file)
    ;   bench_acknowledge(In)
    ).

bench_no_acknowledgement(Cause) :-
    throw(error(io_error(read, perf_control),
                context(bench_acknowledge/1,
                        'perf did not acknowledge: it may have failed to open \c
                         its counter, which it does while another session holds \c
                         the PMU'-Cause))).

%%%% Running one %%%%

bench_run(Case, Size, Phase) :-
    (   bench_case(Case, Size, Setup, Operation, Count, Expected)
    ->  true
    ;   format(user_error, "workload.pl: no case ~w~n", [Case]), halt(2)
    ),
    call(Setup),
    bench_phase(Phase, Operation, Count, Expected).

bench_phase(window, Operation, Count, Expected) :-
    (   getenv('METTA_PERF_CONTROL_FD', _)
    ->  bench_window(bench_operation(Operation, Count, Expected))
    ;   format(user_error,
               "workload.pl: the window phase needs perf's control pipes; run \c
                it through extensions/mork/bench.sh~n", []),
        halt(6)
    ).
%The counters phase brackets the operation alone: inferences are the Prolog
%side, which is deterministic and blind to everything the Rust library does,
%and cputime is the process clock, which is not. Both are printed for the
%driver to record beside the perf samples.
bench_phase(counters, Operation, Count, Expected) :-
    statistics(inferences, Inferences0),
    statistics(cputime, Cpu0),
    bench_operation(Operation, Count, Expected),
    statistics(inferences, Inferences1),
    statistics(cputime, Cpu1),
    Inferences is Inferences1 - Inferences0,
    Cpu is Cpu1 - Cpu0,
    format("inferences=~d cputime=~9f~n", [Inferences, Cpu]).

%The operation, with its answer checked. A case that stopped doing its work
%would otherwise pin a boot and read green forever.
bench_operation(Operation, Count, Expected) :-
    (   call(Operation)
    ->  true
    ;   format(user_error, "workload.pl: the operation failed~n", []), halt(3)
    ),
    (   Count =:= Expected
    ->  true
    ;   format(user_error, "workload.pl: answered ~d, expected ~d~n",
               [Count, Expected]),
        halt(4)
    ).

main :-
    current_prolog_flag(argv, Argv),
    (   Argv = [extensions, Case, SizeText, Phase]
    ->  true
    ;   format(user_error,
               "workload.pl: argv is `extensions <case> <size> <phase>`, got ~q~n",
               [Argv]),
        halt(2)
    ),
    atom_number(SizeText, Size),
    (   metta_extension_loaded(mork)
    ->  true
    ;   format(user_error,
               "workload.pl: the mork seat is not loaded, so this would \c
                measure a boot; run sh extensions/mork/build.sh~n", []),
        halt(5)
    ),
    bench_run(Case, Size, Phase).

:- initialization(main, main).
