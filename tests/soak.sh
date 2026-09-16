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

# This script's own directory, so the helpers can reach Anki.js regardless of
# where it was invoked from.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PLUGIN=yamz8.omanki
STATE="$HOME/.local/state/omarchy/omanki.json"
STATE_DIR="$(dirname "$STATE")"

# The settings group edits the real shell.json, for the same reason the add
# tests edit the real deck: a setting only reaches a surface by way of the
# shell that reads it. Restored on the way out on every path.
CONFIG="$HOME/.config/omarchy/shell.json"

# Which deck the plugin will actually use, worked out the way the plugin works
# it out: from this plugin's `deck` setting in shell.json, with `~` expanded,
# falling back to the default when the setting is absent or empty.
#
# This was hardcoded to the default path, which is wrong the moment the setting
# points anywhere else — and it failed in the worst available way. Every add
# landed in the configured deck while every assertion counted cards in the
# default one, so a working add path looked like it silently did nothing; five
# assertions failed for a reason none of them could express. Worse, the file
# backed up and restored was not the file being written, so a configured deck
# quietly accumulated the soak's own cards while an untouched one was carefully
# preserved. The test has to read the setting or it is testing a file nobody
# uses.
resolve_deck() {
  python3 - "$CONFIG" "$PLUGIN" "$HOME" <<'DECKPY'
import json, sys
config, plugin, home = sys.argv[1], sys.argv[2], sys.argv[3]
default = home + "/.local/share/omanki/cards.json"

configured = ""
try:
    doc = json.load(open(config))
except Exception:
    doc = {}
for section in doc.get("bar", {}).get("layout", {}).values():
    for entry in section:
        if isinstance(entry, dict) and entry.get("id") == plugin:
            configured = str(entry.get("deck") or "").strip()

# Anki.js resolveDeck, in Python. Kept deliberately literal so the two can be
# read side by side.
if not configured:                print(default)
elif configured == "~":           print(home)
elif configured.startswith("~/"): print(home + configured[1:])
else:                             print(configured)
DECKPY
}

DECK="$(resolve_deck)"
[ -n "$DECK" ] || { echo "could not work out which deck the plugin will use"; exit 2; }

# The add-a-card tests write to the real deck, so it is put back on the way
# out — including on an interrupt, since leaving someone's deck edited because
# a test was cancelled would be worse than the test not running at all.
DECK_BACKUP="$(mktemp)"
[ -f "$DECK" ] && cp "$DECK" "$DECK_BACKUP"

CONFIG_BACKUP="$(mktemp)"
[ -f "$CONFIG" ] && cp "$CONFIG" "$CONFIG_BACKUP"

# The scheduling progress is the one file this script deletes outright — reset()
# needs a clean slate before a group, and several groups start with one. It was
# also the one file never put back, so running the soak silently destroyed real
# review history: every interval, ease and lapse count earned on the deck this
# is pointed at. Backed up and restored like the other two, so a clean slate
# lasts for the run rather than forever.
#
# Whether it existed at all is tracked separately, because an absent progress
# file and an empty one are different states and restoring the wrong one would
# leave the soak's own answers behind.
STATE_BACKUP="$(mktemp)"
STATE_EXISTED=no
[ -f "$STATE" ] && { cp "$STATE" "$STATE_BACKUP"; STATE_EXISTED=yes; }

restore_files() {
  [ -s "$DECK_BACKUP" ] && cp "$DECK_BACKUP" "$DECK"
  [ -s "$CONFIG_BACKUP" ] && cp "$CONFIG_BACKUP" "$CONFIG"
  # No backup to copy means there was nothing there to begin with, so the
  # honest restore is to take the soak's own progress away again.
  if [ "$STATE_EXISTED" = yes ]; then cp "$STATE_BACKUP" "$STATE"; else rm -f "$STATE"; fi
  rm -f "$DECK_BACKUP" "$CONFIG_BACKUP" "$STATE_BACKUP"
}
trap restore_files EXIT INT TERM

# Anything the shell logged about this plugin while the soak ran. A view that
# renders at all can still be throwing on every binding, and that never
# reaches an assertion about a file.
SINCE="$(date '+%Y-%m-%d %H:%M:%S')"

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

# Every action here is asynchronous: a keystroke starts a read, a merge and a
# write, and the file changes some time after the key is pressed. Asserting
# after a fixed sleep tests the sleep, not the plugin — it fails when the
# machine is busy and passes when it is not. So poll for the expected value and
# report the last thing seen if it never arrives; a real failure still fails,
# it just takes the timeout to say so.
expect_soon() { # label expected probe-arg
  local label="$1" want="$2" what="$3" got=""
  for _ in $(seq 1 25); do
    got="$(probe "$what")"
    [ "$got" = "$want" ] && { ok "$label ($got)"; return; }
    sleep 0.2
  done
  bad "$label — expected $want, got $got"
}

# Did the plugin log a refusal matching this pattern since the run began?
#
# "The deck did not change" is a negative assertion, and an add that never
# reached the deck at all satisfies it just as well as one the plugin correctly
# turned down. Asserting the stated reason is what tells the two apart, and it
# is the only assertion here that would have failed loudly on a misdirected add
# rather than passing quietly.
refused_since() { # pattern since
  journalctl --user --since "$2" --no-pager 2>/dev/null \
    | grep -F "omanki: add refused:" \
    | grep -qiE "$1"
}

expect_refusal() { # label pattern since
  local label="$1" pattern="$2" since="$3"
  for _ in $(seq 1 25); do
    refused_since "$pattern" "$since" && { ok "$label"; return; }
    sleep 0.2
  done
  bad "$label — nothing matching /$pattern/ was logged"
  echo "         refusals logged since ${since}:"
  journalctl --user --since "$since" --no-pager 2>/dev/null \
    | grep -F "omanki: add refused:" | tail -3 | sed "s/^/           /" \
    || echo "           (none at all)"
}

expect_deck_soon() { # label expected
  local label="$1" want="$2" got=""
  for _ in $(seq 1 25); do
    got="$(deck_count)"
    [ "$got" = "$want" ] && { ok "$label ($got)"; return; }
    sleep 0.2
  done
  bad "$label — expected $want, got $got"
  # A count that did not move says nothing about why it did not move, and the
  # answer has twice turned out to be that the count was of the wrong file.
  # Name the deck and show what is in it, so a wrong path, a refused add and a
  # deck that stopped parsing are told apart from the output alone.
  echo "         deck: $DECK"
  echo "         have: $(deck_fronts)"
}

reveal_and_grade() { wtype " "; sleep 0.7; wtype "$1"; sleep 1.3; }
key()              { wtype "$1"; sleep 1.3; }

panel_open()    { omarchy-shell "$PLUGIN" open  >/dev/null 2>&1; sleep 2.2; }
panel_close()   { omarchy-shell "$PLUGIN" close >/dev/null 2>&1; sleep 1.2; }
overlay_toggle(){ omarchy-shell shell toggle "$PLUGIN" >/dev/null 2>&1; sleep 2.2; }

reset() { rm -f "$STATE"; sleep 0.4; }

# Settings are read when the shell builds a surface, so changing one means
# restarting the shell and waiting for it to answer again rather than sleeping
# a guessed number of seconds.
wait_for_shell() {
  for _ in $(seq 1 60); do
    [ "$(omarchy-shell shell ping 2>/dev/null)" = "ok" ] && { sleep 1.5; return 0; }
    sleep 0.5
  done
  return 1
}

restart_shell() {
  omarchy restart shell >/dev/null 2>&1
  wait_for_shell
}

# Write one setting onto this plugin's entry in shell.json. The value is JSON,
# so a number stays a number and a list stays a list.
set_setting() { # key json-value
  python3 - "$CONFIG" "$PLUGIN" "$1" "$2" <<'PYEOF'
import json, sys
path, plugin, key, value = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
doc = json.load(open(path))
for section in doc.get("bar", {}).get("layout", {}).values():
    for entry in section:
        if entry.get("id") == plugin:
            entry[key] = json.loads(value)
json.dump(doc, open(path, "w"), indent=2)
PYEOF
}

# The last few fronts in the deck, for a failure that needs to say what landed
# rather than only how many things did.
deck_fronts() {
  python3 - "$DECK" <<'PY'
import json, os, sys
p = sys.argv[1]
if not os.path.exists(p): print("(no such file)"); raise SystemExit
try:
    d = json.load(open(p))
except Exception as e:
    print("(does not parse: %s)" % e); raise SystemExit
cards = d if isinstance(d, list) else d.get("cards", [])
fronts = [str(c.get("front", "")) for c in cards if isinstance(c, dict)]
tail = fronts[-4:]
print((", ".join(repr(f) for f in tail) or "(empty)") + (" (+%d earlier)" % (len(fronts) - len(tail)) if len(fronts) > len(tail) else ""))
PY
}

# The id the plugin will give the first card in the deck, computed by the
# plugin's own hashId rather than reimplemented here. A card is identified by a
# hash of its front, and a second implementation of that hash is a second thing
# to get wrong - seeded state that attaches to nothing looks exactly like a
# scheduler that ignored it.
first_card_id() {
  node -e '
    const fs = require("fs")
    const src = fs.readFileSync(process.argv[1], "utf8")
    const G = {}
    new Function("e", src + "\nfor (const k of [\"parseDeck\"]) e[k] = eval(k)")(G)
    const cards = G.parseDeck(fs.readFileSync(process.argv[2], "utf8")).cards
    process.stdout.write(cards.length ? cards[0].id : "")
  ' "$PWD/Anki.js" "$DECK"
}

# Put one card into review with a chosen number of lapses, so the next "again"
# is the one that reaches the threshold. Lapsing a card eight times through the
# surface is not possible in a sitting: each lapse schedules it ten minutes out.
seed_lapses() { # id lapses
  python3 - "$STATE" "$1" "$2" <<'SEEDPY'
import json, os, sys, time
path, card, lapses = sys.argv[1], sys.argv[2], int(sys.argv[3])
now = int(time.time())
doc = {"reviews": {}}
if os.path.exists(path):
    try:
        doc = json.load(open(path))
    except Exception:
        pass
doc.setdefault("reviews", {})[card] = {
    "phase": "review", "due": now - 60, "interval": 30 * 86400, "ease": 2300,
    "reps": 40, "lapses": lapses, "step": 0, "updated": now,
    "firstDay": "2026-01-01", "leech": False, "suspended": False,
}
os.makedirs(os.path.dirname(path), exist_ok=True)
open(path, "w").write(json.dumps(doc))
SEEDPY
}

# One field of one card, or "-" when the card has no entry.
state_field() { # id field
  python3 - "$STATE" "$1" "$2" <<'FIELDPY'
import json, os, sys
path, card, field = sys.argv[1], sys.argv[2], sys.argv[3]
if not os.path.exists(path):
    print("-"); raise SystemExit
try:
    r = json.load(open(path)).get("reviews", {})
except Exception:
    print("-"); raise SystemExit
if card not in r:
    print("-"); raise SystemExit
print(json.dumps(r[card].get(field)))
FIELDPY
}

expect_field_soon() { # label id field expected
  local label="$1" card="$2" field="$3" want="$4" got=""
  for _ in $(seq 1 25); do
    got="$(state_field "$card" "$field")"
    [ "$got" = "$want" ] && { ok "$label ($got)"; return; }
    sleep 0.2
  done
  bad "$label — expected $want, got $got"
  echo "         state: $STATE"
  echo "         card:  $card"
}

deck_count() {
  python3 - "$DECK" <<'PY'
import json, os, sys
p = sys.argv[1]
if not os.path.exists(p): print(0); raise SystemExit
try:
    d = json.load(open(p))
except Exception:
    print(-1); raise SystemExit
cards = d if isinstance(d, list) else d.get("cards", [])
print(len(cards))
PY
}

# front, back, tags — enter moves between fields and commits from the last.
type_card() {
  wtype "$1"; sleep 0.3; wtype -k Return; sleep 0.3
  wtype "$2"; sleep 0.3; wtype -k Return; sleep 0.3
  [ -n "${3:-}" ] && { wtype "$3"; sleep 0.2; }
  wtype -k Return; sleep 1.8
}

command -v wtype >/dev/null || { echo "wtype is required"; exit 2; }
omarchy-shell "$PLUGIN" close >/dev/null 2>&1

# Which files this run will touch. All three are written to and all three are
# restored, and the deck in particular is whichever one the settings point at,
# so a run that goes wrong should not leave you guessing which file it meant.
echo "deck:   $DECK"
echo "state:  $STATE"
echo "config: $CONFIG"
echo "(all three are restored on exit, including on an interrupt)"

group "a configured setting reaches both surfaces"
# Both surfaces are handed their settings by the shell, but not by the same
# route: a bar widget is given its shell.json entry directly, while an overlay
# has to find its own. The overlay looked for it on an object third-party
# plugins are not given, so it quietly ran on defaults -- the deck it read, the
# cards it introduced and the tag filter it applied were all the built-in ones
# while the panel beside it honoured the file. Nothing about a default install
# shows that: with no settings on the entry, the defaults are the right answer.
#
# So configure one and watch it bite. The new-card allowance is the cheapest
# setting to see from outside: with two a day, a surface introduces two cards
# and then has nothing left to show, however many the deck holds.
set_setting newPerDay 2

# A second setting in the same restart, because the two are checked the same
# way and a restart is the slow part. lapsePercent 0 is Anki's default rather
# than this plugin's, so a surface that quietly fell back to the built-in 50
# would keep half the interval and be caught.
set_setting lapsePercent 0
restart_shell || bad "shell did not come back after setting the two"

reset; panel_open
reveal_and_grade 3
reveal_and_grade 3
reveal_and_grade 3
expect_soon "the panel stops at the configured allowance"  2 answered
panel_close

# A 30-day card lapsed at 0% must come back to a single day. At the built-in
# 50% it would keep fifteen, which is the difference a surface running on
# defaults would show.
lapse_id="$(first_card_id)"
if [ -z "$lapse_id" ]; then
  bad "could not work out the first card's id for the lapse check"
else
  reset; seed_lapses "$lapse_id" 0; panel_open
  reveal_and_grade "1"
  expect_field_soon "the panel honours the configured lapse" "$lapse_id" "interval" "86400"
  panel_close
fi

reset; overlay_toggle
reveal_and_grade 3
reveal_and_grade 3
reveal_and_grade 3
expect_soon "the overlay stops at the same allowance"      2 answered
overlay_toggle

if [ -n "$lapse_id" ]; then
  reset; seed_lapses "$lapse_id" 0; overlay_toggle
  reveal_and_grade "1"
  expect_field_soon "the overlay honours the same lapse setting" "$lapse_id" "interval" "86400"
  overlay_toggle
fi

cp "$CONFIG_BACKUP" "$CONFIG"
restart_shell || bad "shell did not come back after restoring the config"

group "many answers in one session all persist"
# The writer bug dropped everything after the first.
reset; panel_open
reveal_and_grade 3
expect_soon "one answer saved"    1 answered
reveal_and_grade 3
expect_soon "two answers saved"   2 answered
reveal_and_grade 4
expect_soon "three answers saved" 3 answered
reveal_and_grade 1
expect_soon "four answers saved"  4 answered

group "undo walks back and re-answering moves forward again"
key u
expect_soon "undo takes one back"        3 answered
key u
expect_soon "undo again takes another"   2 answered
reveal_and_grade 3
expect_soon "re-answering counts again"  3 answered
panel_close

group "the two surfaces do not erase each other"
# The clobbering bug: the overlay answers, then the panel saves from a copy
# that predates those answers.
reset
panel_open                 # panel loads an empty document and keeps it
overlay_toggle             # overlay opens on top; the panel stays live
reveal_and_grade 4
reveal_and_grade 4
expect_soon "overlay answered two" 2 answered
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

group "cards can be added, and added again"
# The writer closes stdin after each document, which is what broke the progress
# writer on its second use. One add cannot show that; two can.
reset
overlay_toggle
base="$(deck_count)"
wtype "a"; sleep 1.2                      # open the composer
type_card "Soak card one" "answer one" ""
expect_deck_soon "the first card is written" "$((base + 1))"
type_card "Soak card two" "answer two" "soak"
expect_deck_soon "the second card is written too" "$((base + 2))"
type_card "Soak card three" "answer three" ""
expect_deck_soon "and a third" "$((base + 3))"

dup_since="$(date '+%Y-%m-%d %H:%M:%S')"
type_card "Soak card one" "a different answer" ""
sleep 2   # nothing to wait for — let a wrongly-accepted add land before denying it
expect "a duplicate front is refused" "$((base + 3))" "$(deck_count)"
expect_refusal "and refused for being a duplicate, not silently" "already in the deck" "$dup_since"

wtype -k Escape; sleep 0.8                # back to review

group "a deck it cannot parse is left alone"
printf '{ this is not json' > "$DECK"
before_broken="$(md5sum "$DECK" | cut -d" " -f1)"
broken_since="$(date '+%Y-%m-%d %H:%M:%S')"
wtype "a"; sleep 1.2
type_card "Should not be written" "nope" ""
sleep 2   # same: give a wrongly-accepted write time to happen
after_broken="$(md5sum "$DECK" | cut -d" " -f1)"
expect "the unparseable deck is untouched" "$before_broken" "$after_broken"
expect_refusal "and refused for not parsing, not silently" "not valid JSON" "$broken_since"
wtype -k Escape; sleep 0.8
cp "$DECK_BACKUP" "$DECK"; sleep 0.5
wtype "r"; sleep 1.5                      # reload the restored deck

# A refusal must not wedge the composer: proving the deck survived is only
# half of it, since a permanently stuck `adding` flag would also leave the
# file untouched and look identical from here.
recovered_base="$(deck_count)"
wtype "a"; sleep 1.2
type_card "Soak card after refusal" "still working" ""
expect_deck_soon "adding still works after a refusal" "$((recovered_base + 1))"
wtype -k Escape; sleep 0.8
cp "$DECK_BACKUP" "$DECK"; sleep 0.5

group "the other views survive being opened"
wtype "r"; sleep 1.5                      # pick up the restored deck
wtype "s"; sleep 1.5                      # statistics
ok "statistics opened"
wtype "a"; sleep 1.2                      # composer from stats
wtype -k Escape; sleep 0.8                # back to review
reveal_and_grade 3
expect_soon "reviewing still works after touring the views" 1 answered
overlay_toggle

group "a card that lapses too often is taken out, and can be put back"
# The unit tests prove the rule; this proves the rule reaches the file through
# a real keystroke, that the card actually leaves the rotation, and that the
# way back works - restoring is a write path of its own, and this plugin's
# shipped bugs have all been in write paths.
reset
leech_id="$(first_card_id)"
if [ -z "$leech_id" ]; then
  bad "could not work out the first card's id - is the deck empty?"
else
  # One lapse below the default threshold, and due, so it is the card in front
  # of you and the next "again" is the eighth.
  seed_lapses "$leech_id" 7
  overlay_toggle

  reveal_and_grade "1"
  expect_field_soon "the eighth lapse marks the card a leech" "$leech_id" "leech" "true"
  expect_field_soon "and suspends it" "$leech_id" "suspended" "true"
  expect_field_soon "the lapse itself still counted" "$leech_id" "lapses" "8"

  # Out of the rotation means out: the card must not come back as the next one
  # to answer, and must not be counted as waiting either.
  #
  # Polled rather than read once. Nothing should be writing between the reload
  # and the read, but "should be" is what a fixed sleep always assumes, and this
  # was the only positive assertion here still making that assumption.
  key "r"
  expect_field_soon "it stays suspended across a reload" "$leech_id" "suspended" "true"

  # Restoring lives in the statistics, which is also the only place the count
  # is shown.
  key "s"
  key "l"
  expect_field_soon "l puts the card back" "$leech_id" "suspended" "false"
  expect_field_soon "and keeps the leech mark" "$leech_id" "leech" "true"

  key "s"
  overlay_toggle
fi

group "the panel's statistics open, and leave the cards where they were"
# The panel grew its own statistics, laid out in tabs rather than as the single
# column the overlay can afford. A view that throws on every binding still
# "opens", so this walks the strip and then checks the cards are still there to
# be answered - and the log scan at the end of this file catches the throwing.
reset
panel_open
key "s"
wtype -k Right; sleep 0.5
wtype -k Right; sleep 0.5
wtype -k Right; sleep 0.5    # wraps back round to the first
ok "the statistics tabs were walked"
key "s"
reveal_and_grade 3
expect_soon "the panel still reviews after touring its tabs" 1 answered
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

group "the shell logged no errors from this plugin"
errs="$(journalctl --user --since "$SINCE" --no-pager 2>/dev/null \
  | grep -iE "omanki|CardComposer|StatsView|Reviewer\.qml" \
  | grep -iE "TypeError|ReferenceError|Cannot read|is not a function|Unable to assign|non-existent" \
  | head -5)"
if [ -z "$errs" ]; then
  ok "no QML errors logged"
else
  bad "QML errors logged:"
  echo "$errs" | sed "s/^/         /"
fi

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
