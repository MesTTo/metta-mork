#!/bin/sh
# Purpose: this seat's tests, standalone. `sh extensions/mork/test.sh` is what a
#   developer runs and what extensions/mork/check.sh's mork-seat lane runs, so
#   the gate and the desk exercise one entry point.
# Assumes: swipl on PATH. The suites decide for themselves whether the backend
#   is built; nothing here needs cargo.
# Guarantees:
#   - the plunit suite runs with the `extensions` token, which is the only
#     configuration in which the engine reads this seat at all
#     [source: engine/metta.pl, the metta_load_extensions/1 directive].
#   - a run that measured nothing SAYS so: the built half of the suite is
#     conditioned on the seat being loaded, so on a tree carrying both shared
#     objects this requires the suite to report every test rather than a
#     skipped file reading as a pass. That is the failure mode a worktree
#     produces, since the artefacts are gitignored and a fresh checkout has
#     neither.
#   - an error printed while the suite LOADS fails the run, because the exit
#     code cannot see it: `-t halt` halts 0, run_tests reports only the tests
#     that registered, and a clause whose body raises during goal expansion is
#     dropped along with its registration, so the test does not run, does not
#     fail and does not appear in the count. The same reading check.sh's plunit
#     lane makes, for the same reason.
# Open Obligations:
#   To Do: None
#   Hacks: None
#   Future Enhancements: None
set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

command -v swipl >/dev/null || {
    echo "test.sh: swipl is not on PATH; this seat is a Prolog provider" >&2
    exit 2
}

status=0
log=$(mktemp "${TMPDIR:-/tmp}/mork-test.XXXXXX")
trap 'rm -f "$log"' EXIT HUP INT TERM

# Which configuration this run is measuring, said before any result, because
# the two differ in what the suite covers and a reader has to know which one
# produced the line below.
built=yes
for artefact in mork_ffi/target/release/libmork_ffi.so mork_ffi/morklib.so; do
    [ -f "$HERE/$artefact" ] || built=no
done
if [ "$built" = yes ]; then
    echo "mork: both shared objects are present, so the whole suite runs"
else
    echo "mork: the backend is not built, so only the seat-absent tests run;" \
         "run sh extensions/mork/build.sh for the rest"
fi

# Redirected to a file rather than piped, because a pipeline reports the LAST
# command's status and swipl failing would be masked by the reader succeeding.
swipl -g "set_test_options([format(log)]), run_tests" -t halt \
      "$HERE/tests/mork_seat.plt" -- extensions > "$log" 2>&1 || status=1
cat "$log"

if grep -q "^ERROR" "$log"; then
    echo "mork: the suite printed an error; a clause that fails to compile is" \
         "dropped silently and its test never runs"
    status=1
fi
if grep -q "succeeded with choicepoint" "$log"; then
    echo "mork: a test succeeded with a choicepoint"
    status=1
fi
# The skip trap, closed at the runner. On a built tree every test is reachable,
# so a report of anything less than the whole file means the conditions read
# the seat as absent while its artefacts are on disk, which is a run that
# measured the seat by not measuring it. plunit says "All N tests passed" and
# says nothing at all about the ones a condition skipped, so the count is the
# only signal there is; it is read off the suite rather than written here, so
# adding a test cannot leave this guard behind.
declared=$(grep -c '^test(' "$HERE/tests/mork_seat.plt")
if [ "$built" = yes ] && ! grep -q "All $declared tests passed" "$log"; then
    echo "mork: both shared objects are present and the suite did not report" \
         "all $declared tests; a conditioned suite that skips on a built tree" \
         "is a lane that measured nothing"
    status=1
fi

sh "$HERE/tests/test_missing_artefacts.sh" || status=1

exit $status
