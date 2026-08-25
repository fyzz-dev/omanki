#!/usr/bin/env bash
#
# Integration soak for the omanki surfaces.
#
#   tests/soak.sh
#
# The unit tests exercise Anki.js, which is pure and knows nothing about
# processes, files, or two surfaces being open at once. Every bug this plugin
# has actually shipped lived in that gap and survived a green unit suite:
#
#   - the writer closed stdin after its first document and never reopened it,
#     so every save after the first in a shell session was silently dropped;
#   - each surface wrote the whole document from its own memory, so the bar
#     panel saving after the overlay had answered erased those answers.
#
# Both are invisible to a single action in a single surface, which is exactly
# how they were missed. This script does many actions, in both surfaces, and
# reads the file back after each one.
#
# It drives the real shell with real keystrokes, so it needs a running
# omarchy-shell, a working wtype, and the focus it takes while it runs. It is
# deliberately not part of the unit suite.

set -uo pipefail

PLUGIN=yamz8.omanki
STATE="$HOME/.local/state/omarchy/omanki.json"
STATE_DIR="$(dirname "$STATE")"

pass=0; fail=0
ok()   { pass=$((pass+1)); echo "  ok   $1"; }
bad()  { fail=$((fail+1)); echo "  FAIL $1"; }
group(){ echo; echo "$1"; }

# entries | introduced-today | reps for a given card index
probe() {
  python3 - "$STATE" "$1" <<'PY'
import json, os, sys, time
path, what = sys.argv[1], sys.argv[2]
if not os.path.exists(path):
    print({"entries": 0, "answered": 0}.get(what, 0)); raise SystemExit
d = json.load(open(path))
r = d.get("reviews", {})
if what == "entries":
    print(len(r))
elif what == "answered":
    # Cards with any history at all: an undone card goes back to reps 0.
    print(sum(1 for v in r.values() if v.get("reps", 0) > 0))
elif what == "ids":
    print(",".join(sorted(k for k, v in r.items() if v.get("reps", 0) > 0)))
PY
}

expect() { # label expected actual
  if [ "$2" = "$3" ]; then ok "$1 ($3)"; else bad "$1 — expected $2, got $3"; fi
}

reveal_and_grade() { wtype " "; sleep 0.7; wtype "$1"; sleep 1.3; }
key()              { wtype "$1"; sleep 1.3; }

panel_open()    { omarchy-shell "$PLUGIN" open  >/dev/null 2>&1; sleep 2.2; }
panel_close()   { omarchy-shell "$PLUGIN" close >/dev/null 2>&1; sleep 1.2; }
overlay_toggle(){ omarchy-shell shell toggle "$PLUGIN" >/dev/null 2>&1; sleep 2.2; }

reset() { rm -f "$STATE"; sleep 0.4; }

command -v wtype >/dev/null || { echo "wtype is required"; exit 2; }
omarchy-shell "$PLUGIN" close >/dev/null 2>&1

group "many answers in one session all persist"
# The writer bug dropped everything after the first.
reset; panel_open
reveal_and_grade 3
expect "one answer saved"    1 "$(probe answered)"
reveal_and_grade 3
expect "two answers saved"   2 "$(probe answered)"
reveal_and_grade 4
expect "three answers saved" 3 "$(probe answered)"
reveal_and_grade 1
expect "four answers saved"  4 "$(probe answered)"

group "undo walks back and re-answering moves forward again"
key u
expect "undo takes one back"        3 "$(probe answered)"
key u
expect "undo again takes another"   2 "$(probe answered)"
reveal_and_grade 3
expect "re-answering counts again"  3 "$(probe answered)"
panel_close

group "the two surfaces do not erase each other"
# The clobbering bug: the overlay answers, then the panel saves from a copy
# that predates those answers.
reset
panel_open                 # panel loads an empty document and keeps it
overlay_toggle             # overlay opens on top; the panel stays live
reveal_and_grade 4
reveal_and_grade 4
overlay_answers="$(probe answered)"
expect "overlay answered two" 2 "$overlay_answers"
overlay_ids="$(probe ids)"
overlay_toggle             # close the overlay; the panel never reloaded
reveal_and_grade 3         # panel answers from its stale copy
final_ids="$(probe ids)"

# The panel's stale queue still starts on the card the overlay answered first,
# so it re-answers that one and the total need not grow. What must hold is
# that nothing the overlay did disappeared.
missing=""
IFS=, read -ra want <<< "$overlay_ids"
for id in "${want[@]}"; do
  case ",$final_ids," in *,"$id",*) ;; *) missing="$missing $id";; esac
done
if [ -z "$missing" ]; then
  ok "the overlay's answers survive the panel's save ($overlay_ids still present)"
else
  bad "the panel's save erased:$missing (had $overlay_ids, now $final_ids)"
fi
panel_close

group "nothing is left running or stranded"
# Scoped to children of the shell, not a bare `pgrep -f`. A bare match also
# catches any ancestor whose own command line happens to contain the pattern
# text — including the terminal running this script — and reports a hung
# writer that does not exist.
#
# And a save in flight at the moment of checking is normal, not a leak: the
# distinction is whether it ever finishes. So poll for quiescence rather than
# sampling once, which is a race that reports a busy writer as a stuck one.
shell_pid="$(pgrep -x quickshell | head -1)"
hung=1
if [ -z "$shell_pid" ]; then
  hung=0   # no shell running; nothing of ours can be stuck
else
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    hung="$(pgrep -P "$shell_pid" -fc 'omanki-write|omanki-merge' 2>/dev/null || true)"
    hung="${hung:-0}"
    [ "$hung" -eq 0 ] && break
    sleep 1
  done
fi
expect "no writer or merger left hung" 0 "$hung"
stray="$(find "$STATE_DIR" -maxdepth 1 -name '.omanki.*' 2>/dev/null | wc -l)"
expect "no temp files stranded" 0 "$stray"

reset
echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
