#!/bin/sh
# Purpose: run this seat in the configurations a built tree can never reach, by
#   pointing a real engine boot at a seat whose artefacts are genuinely absent
#   from disk.
#
#   The absent-backend checks let the loader read the shipped
#   extensions/mork/extension.pl and resolve its
#   needs(artefact(...)) against a directory where the file is not there, and
#   write the record itself. The final invariant control deliberately plants
#   a false loaded record in its own process after those real loader checks.
#
#   The tree is built from symlinks so the seat's control file is the shipped
#   byte-for-byte one. engine/ and lib/ are real directories of per-file
#   links, never a link to the directory itself, for two reasons.
#   engine/../extensions resolves through a directory symlink to the REAL
#   checkout at the filesystem while SWI normalises the `..` lexically, and the
#   two then disagree about which seat is being read. And a boot from this
#   tree compiles the library halves it loads beside their sources, so through
#   a linked lib/ it wrote its artifacts INTO THE CHECKOUT, recorded under this
#   tree's path: SWI loads an artifact from a directory other than the one it
#   was saved in as moved, rewrites every source path it recorded and calls
#   system:'$translated_source'/2 for each at every load, 8 inferences per
#   one-source library that every process on the checkout then paid, and the
#   twins lane read exactly that on the two twins importing minimal_metta_lib
#   in three gates while no run outside a gate could [measured 2026-09-12: the
#   minimal_metta twin 188,049 through an artifact compiled under a symlink to
#   its library's directory, 188,041 through one compiled in place, the import
#   itself 14,520 against 14,512; command=python
#   extensions/python/tools/twin_coverage.py, one twin child under the lane's
#   environment, after qcompile of lib/minimal_metta_lib/minimal_metta_lib.pl
#   through a symlink to its directory;
#   fixture=examples/ch20-extending-the-engine/20-02-metta-written-in-metta/04-minimal_metta.metta;
#   commit=23ed2559a7c9b5712e1f6f4710ed02f8d5c6a23d]. *.qlf and __pycache__ are not linked, so this tree
#   compiles and caches for itself, the closing check below says the checkout
#   gained no artifact while it ran, and tests/checks/check_qlf_provenance.py
#   is what refuses one written elsewhere should it ever land there again.
# Guarantees:
#   - no boot from a scratch tree writes an artifact into the checkout: every
#     *.qlf under the checkout's engine/ and lib/ predates this test's start
#     when it ends [tested: sh check.sh mork-seat; commit=23ed2559a7c9b5712e1f6f4710ed02f8d5c6a23d]
#   - with an artefact absent the seat loads nothing and says nothing: a boot
#     that reads the seats writes zero bytes to stdout and zero to stderr, and
#     records the unmet need by name.
#   - !(require-extension! mork) refuses naming the seat, the absent artefact's
#     tree-relative path, and the command that builds it, and through a file
#     load it names the requiring file as well.
#   - a HALF-built tree, libmork_ffi.so present and morklib.so absent, answers
#     exactly as an unbuilt one: both artefacts are declared needs.
#   - declaring only the first artefact reaches the broken entry, reports its
#     source path and leaves the seat unregistered; a false loaded record
#     planted afterwards still fails mork_seat.plt's unconditional invariant
#     by name [tested: sh check.sh mork-seat; commit=8ee8fcd4e43a932131909f7c58ad4fbe4dcf8d1d].
# Fails when:
#   - swipl is absent, which is reported rather than skipped: this seat is a
#     Prolog provider and there is nothing to test without an engine.
# Owns resources: the EXIT trap removes the private fixture tree; bounded.sh
#   reaps children, including the one that owns the planted loaded record.
# Open Obligations:
#   To Do: None
#   Hacks: None
#   Future Enhancements: None
set -eu

command -v swipl >/dev/null || {
    echo "FAIL: swipl is not on PATH, so no engine can be booted" >&2
    exit 1
}

seat_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
project_dir=$(CDPATH= cd -- "$seat_dir/../.." && pwd)

# One spelling of the bound, implemented in bounded.sh, which every runner in
# this tree and a command typed by hand all reach.
bounded() { sh "$project_dir/bounded.sh" "$@"; }

probe=$(mktemp -d "${TMPDIR:-/tmp}/mork-missing-artefacts.XXXXXX")
trap 'rm -rf "$probe"' EXIT HUP INT TERM
# The instant this test started, for the closing check that the checkout gained
# no compiled artifact while it ran.
: > "$probe/started"

# One rule for a source directory: a real directory, a link per file, and
# nothing compiled or cached carried over, so a boot from the tree compiles and
# caches for itself. A subshell body, because the recursion would otherwise
# overwrite the caller's loop variables.
link_sources() (
    source_dir="$1"; target_dir="$2"
    mkdir -p "$target_dir"
    for entry in "$source_dir"/*; do
        [ -e "$entry" ] || continue
        name=$(basename "$entry")
        case "$name" in *.qlf|__pycache__) continue ;; esac
        if [ -d "$entry" ] && [ ! -L "$entry" ]; then
            link_sources "$entry" "$target_dir/$name"
        else
            ln -s "$entry" "$target_dir/$name"
        fi
    done
)

# A tree whose only seat is mork, so the glob reads one control file and no
# other seat's state can explain the result. The scratch root's own basename is
# `extensions`, because the refusal writes the seat path from the recorded
# directory's basename and this test reads that text verbatim.
build_tree() {
    tree="$1"
    mkdir -p "$tree/extensions/mork/mork_ffi"
    link_sources "$project_dir/engine" "$tree/engine"
    link_sources "$project_dir/lib" "$tree/lib"
    ln -s "$seat_dir/extension.pl" "$tree/extensions/mork/extension.pl"
    ln -s "$seat_dir/build.sh" "$tree/extensions/mork/build.sh"
    ln -s "$seat_dir/mork_ffi/morkspaces.pl" \
          "$tree/extensions/mork/mork_ffi/morkspaces.pl"
    mkdir -p "$tree/extensions/mork/tests"
    ln -s "$seat_dir/tests/mork_seat.plt" \
          "$tree/extensions/mork/tests/mork_seat.plt"
}

boot() {
    tree="$1"; goal="$2"
    bounded --ceiling 250 \
        swipl -q -g "$goal" -t halt -s "$tree/engine/metta.pl" -- extensions
}

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    shift
    for line in "$@"; do printf '      %s\n' "$line" >&2; done
    exit 1
}

# Every property of an absent backend, over one tree, named by what is missing.
check_absent_backend() {
    tree="$1"; missing="$2"

    boot "$tree" halt > "$probe/boot.out" 2> "$probe/boot.err" ||
        fail "the engine did not boot with $missing absent" \
             "an unbuilt backend is not an error and must not stop a boot" \
             "$(head -3 "$probe/boot.err")"
    for stream in out err; do
        [ -s "$probe/boot.$stream" ] &&
            fail "a seat missing $missing printed on std$stream" \
                 "not built is not an error, and a boot that says so breaks" \
                 "every host that compares process output" \
                 "$(head -3 "$probe/boot.$stream")"
    done

    records=$(boot "$tree" "
        ( metta_extension_loaded(mork) -> writeln('loaded') ; true ),
        forall(metta_extension_unmet(mork, Need),
               ( write('unmet '), writeln(Need) ))
    " 2>&1)
    case "$records" in
        *loaded*) fail "the seat recorded itself loaded with $missing absent" ;;
    esac
    case "$records" in
        *"unmet artefact($missing)"*) ;;
        *) fail "the unmet need for $missing was not recorded by name" \
                "the loader read the control file and answered: $records" ;;
    esac

    refusal=$(boot "$tree" "
        catch(( 'require-extension!'(mork, _), fail ), Error,
              ( message_to_string(Error, Text), write(Text) ))
    " 2>&1)
    for phrase in \
        'extension mork is required and not loaded' \
        "artefact extensions/mork/$missing is absent" \
        'run extensions/mork/build.sh'
    do
        case "$refusal" in
            *"$phrase"*) ;;
            *) fail "the refusal does not say \"$phrase\"" \
                    "a program that needs this backend has to be told which" \
                    "half is missing and what builds it. It said:" "$refusal" ;;
        esac
    done
}

# ---------------------------------------------------------- nothing is built

unbuilt="$probe/unbuilt"
build_tree "$unbuilt"
check_absent_backend "$unbuilt" 'mork_ffi/target/release/libmork_ffi.so'

# The same refusal reached the way lib_mm2 reaches it, so the frame that names
# the requiring file is part of what is checked rather than assumed.
printf '!(require-extension! mork)\n' > "$probe/needs_mork.metta"
in_file=$(boot "$unbuilt" "
    catch(( load_imported_metta_file('$probe/needs_mork.metta', _, '&self'), fail ),
          Error, ( message_to_string(Error, Text), write(Text) ))
" 2>&1 | tail -1)
for phrase in needs_mork.metta 'run extensions/mork/build.sh' 'while loading MeTTa file'; do
    case "$in_file" in
        *"$phrase"*) ;;
        *) fail "a require inside a MeTTa file lost \"$phrase\" from its message" \
                "so one of the requiring file and the remedy is no longer named." \
                "It said: $in_file" ;;
    esac
done

# ------------------------------------------------------- only half is built

half="$probe/half"
build_tree "$half"
mkdir -p "$half/extensions/mork/mork_ffi/target/release"
# The declared artefact, and only it: an empty file rather than a link to the
# built one, because what this configuration needs is a path that exists and
# nothing else about it.
: > "$half/extensions/mork/mork_ffi/target/release/libmork_ffi.so"
check_absent_backend "$half" 'mork_ffi/morklib.so'

# The old one-artefact declaration passes the needs check and reaches a broken
# entry. Unlike a declared unmet need, that is a load error. loading_loudly/1
# now refuses registration even though SWI prints the directive and continues
# consulting. Both the diagnostic and the absent record are part of the claim.
control="$probe/control"
build_tree "$control"
mkdir -p "$control/extensions/mork/mork_ffi/target/release"
: > "$control/extensions/mork/mork_ffi/target/release/libmork_ffi.so"
rm "$control/extensions/mork/extension.pl"
cat > "$control/extensions/mork/extension.pl" <<'PRE_FIX_CONTROL_FILE'
title('Spaces on MORK''s Rust trie, over the FFI').
needs(artefact('mork_ffi/target/release/libmork_ffi.so')).
needs(predicate(open_shared_object/3)).
entry(engine, 'mork_ffi/morkspaces.pl').
PRE_FIX_CONTROL_FILE

staged=$(boot "$control" "
    ( metta_extension_loaded(mork) -> writeln('loaded') ; writeln('absent') ),
    ( current_predicate(mork/3) -> writeln('mork/3 present') ; writeln('mork/3 absent') )
" 2> "$probe/rejected-entry.log")
[ "$staged" = "$(printf 'absent\nmork/3 absent')" ] ||
    fail "the broken entry was recorded as a working seat: $staged"
for phrase in 'morkspaces.pl' 'the Prolog source did not load cleanly'; do
    grep -Fq "$phrase" "$probe/rejected-entry.log" ||
        fail "the broken entry's refusal lost $phrase" \
             "$(cat "$probe/rejected-entry.log")"
done

# The loader prevents the historical false record now. Plant it explicitly in
# a fresh unbuilt process so the seat's own invariant still proves it can see
# that state, independently of the loader that prevents it.
if bounded --ceiling 250 swipl \
        -g "assertz(metta_engine:metta_extension_loaded(mork)),run_tests(mork_seat:a_recorded_seat_has_a_working_backend_behind_it)" \
        -t halt "$unbuilt/extensions/mork/tests/mork_seat.plt" -- extensions \
        > "$probe/control.log" 2>&1
then
    fail "the seat's own suite passed with the seat recorded loaded and no" \
         "mork/3 behind it, so nothing in it can tell a working backend from" \
         "a broken one:" "$(tail -3 "$probe/control.log")"
fi
case "$(cat "$probe/control.log")" in
    *a_recorded_seat_has_a_working_backend_behind_it*) ;;
    *) fail "the suite went red for some other reason, so the unconditional" \
            "invariant is no longer what catches a broken recorded seat:" \
            "$(tail -10 "$probe/control.log")" ;;
esac

# The tree's own promise, checked: the checkout gained no compiled artifact
# while boots from the scratch trees ran. One that did is named, because every
# process on the checkout would then load it as moved and pay for it.
written=$(find "$project_dir/engine" "$project_dir/lib" -name '*.qlf' -newer "$probe/started")
[ -z "$written" ] ||
    fail "a boot from a scratch tree wrote compiled artifacts into the checkout:" \
         $written \
         "every process on the checkout would load them as moved and pay for it"

echo "ok: an absent artefact loads nothing, says nothing, and refuses by name"
echo "ok: a half-built tree answers exactly as an unbuilt one"
echo "ok: a broken entry refuses registration with its source named"
echo "ok: a planted loaded seat with no backend behind it fails by name"
echo "ok: the checkout gained no compiled artifact from the scratch trees"
