// Scheduling and deck logic for omanki. Kept free of QML types so the
// algorithm is readable on its own and testable under plain node, leaving the
// .qml files as presentation only.

var MINUTE = 60
var HOUR = 3600
var DAY = 86400

// The study day rolls over at 4am rather than midnight, the way Anki's does:
// a card answered at 1am belongs to the day you are still awake in, not the
// one the clock just started.
var ROLLOVER_HOUR = 4

// A new card is shown again after a minute, then after ten, then it graduates.
// Short enough that both steps land inside one sitting.
var LEARNING_STEPS = [1 * MINUTE, 10 * MINUTE]
var RELEARNING_STEPS = [10 * MINUTE]

var GRADUATING_INTERVAL = 1 * DAY
var EASY_INTERVAL = 4 * DAY

// Ease is carried in permille so the arithmetic stays in integers; 2500 is
// SM-2's starting factor of 2.5.
var STARTING_EASE = 2500
var MIN_EASE = 1300
var MAX_EASE = 3000

var HARD_MULTIPLIER = 1.2
var EASY_BONUS = 1.3
var LAPSE_MULTIPLIER = 0.5

var MIN_REVIEW_INTERVAL = 1 * DAY
var MAX_INTERVAL = 36500 * DAY

var GRADES = ["again", "hard", "good", "easy"]

function isGrade(g) {
  return GRADES.indexOf(g) !== -1
}

function clampEase(ease) {
  return Math.max(MIN_EASE, Math.min(MAX_EASE, Math.round(ease)))
}

function clampInterval(seconds) {
  return Math.max(MIN_REVIEW_INTERVAL, Math.min(MAX_INTERVAL, Math.round(seconds)))
}

// Every successful answer has to move the card further out than it was, even
// when the multiplier rounds to nothing — otherwise a card with a short
// interval and a low ease can sit at the same spacing forever.
function grow(interval, factor) {
  return clampInterval(Math.max(interval + DAY, interval * factor))
}

function newState() {
  return {
    phase: "new",
    due: 0,
    interval: 0,
    ease: STARTING_EASE,
    reps: 0,
    lapses: 0,
    step: 0
  }
}

function num(value, fallback) {
  var n = Number(value)
  return isFinite(n) ? n : fallback
}

// State comes off disk, where anything running as the user could have written
// it, so every field is coerced back into range before it reaches the
// scheduler. A nonsense phase is treated as a new card: re-learning something
// is cheap, and scheduling off a garbage interval is not.
function normalizeState(state) {
  if (!state || typeof state !== "object") return newState()

  var phase = String(state.phase || "new")
  if (["new", "learning", "review", "relearning"].indexOf(phase) === -1) return newState()

  var steps = phase === "relearning" ? RELEARNING_STEPS : LEARNING_STEPS
  return {
    phase: phase,
    due: Math.max(0, num(state.due, 0)),
    interval: Math.max(0, Math.min(MAX_INTERVAL, num(state.interval, 0))),
    ease: clampEase(num(state.ease, STARTING_EASE)),
    reps: Math.max(0, Math.round(num(state.reps, 0))),
    lapses: Math.max(0, Math.round(num(state.lapses, 0))),
    step: Math.max(0, Math.min(steps.length - 1, Math.round(num(state.step, 0))))
  }
}

// Answer one card. Returns the next state and never mutates the one passed in,
// so a caller can price every button (see previewIntervals) before committing
// to any of them.
function grade(state, g, now) {
  var s = normalizeState(state)
  if (!isGrade(g)) return s

  var next = {
    phase: s.phase,
    due: s.due,
    interval: s.interval,
    ease: s.ease,
    reps: s.reps + 1,
    lapses: s.lapses,
    step: s.step
  }

  // ------------------------------------------------- new and learning cards
  // Nothing here touches ease: a card you have not learned yet has no history
  // to judge it by, so it graduates on the fixed intervals instead.
  if (s.phase === "new" || s.phase === "learning") {
    var at = s.phase === "new" ? 0 : s.step

    if (g === "again") {
      next.phase = "learning"
      next.step = 0
      next.interval = 0
      next.due = now + LEARNING_STEPS[0]
    } else if (g === "hard") {
      // Repeat the step rather than advance: hard means it was recalled, but
      // not well enough to earn a longer gap.
      next.phase = "learning"
      next.step = at
      next.interval = 0
      next.due = now + LEARNING_STEPS[at]
    } else if (g === "good") {
      var step = at + 1
      if (step >= LEARNING_STEPS.length) {
        next.phase = "review"
        next.step = 0
        next.interval = GRADUATING_INTERVAL
        next.due = now + GRADUATING_INTERVAL
      } else {
        next.phase = "learning"
        next.step = step
        next.interval = 0
        next.due = now + LEARNING_STEPS[step]
      }
    } else {
      // Easy skips the remaining steps entirely.
      next.phase = "review"
      next.step = 0
      next.interval = EASY_INTERVAL
      next.due = now + EASY_INTERVAL
    }
    return next
  }

  // ------------------------------------------------------- relearning cards
  // The interval was already cut when the card lapsed, so leaving relearning
  // restores that reduced interval rather than starting over at a day.
  if (s.phase === "relearning") {
    if (g === "again") {
      next.step = 0
      next.due = now + RELEARNING_STEPS[0]
      return next
    }
    if (g === "hard") {
      next.due = now + RELEARNING_STEPS[s.step]
      return next
    }

    var rstep = s.step + 1
    if (g === "easy" || rstep >= RELEARNING_STEPS.length) {
      next.phase = "review"
      next.step = 0
      next.interval = clampInterval(s.interval)
      next.due = now + next.interval
    } else {
      next.step = rstep
      next.due = now + RELEARNING_STEPS[rstep]
    }
    return next
  }

  // ------------------------------------------------------------ review cards
  if (g === "again") {
    // A lapse costs ease and half the interval, and sends the card back
    // through a short relearning step before it counts as known again.
    next.lapses = s.lapses + 1
    next.ease = clampEase(s.ease - 200)
    next.interval = clampInterval(s.interval * LAPSE_MULTIPLIER)
    next.phase = "relearning"
    next.step = 0
    next.due = now + RELEARNING_STEPS[0]
    return next
  }

  if (g === "hard") {
    next.ease = clampEase(s.ease - 150)
    next.interval = grow(s.interval, HARD_MULTIPLIER)
  } else if (g === "good") {
    next.interval = grow(s.interval, s.ease / 1000)
  } else {
    next.ease = clampEase(s.ease + 150)
    next.interval = grow(s.interval, (next.ease / 1000) * EASY_BONUS)
  }

  next.due = now + next.interval
  return next
}

// What each button would cost, for the labels under them. Anki shows these and
// they are most of what makes a grade choice meaningful rather than a guess.
function previewIntervals(state, now) {
  var out = {}
  for (var i = 0; i < GRADES.length; i++) {
    var g = GRADES[i]
    out[g] = formatInterval(grade(state, g, now).due - now)
  }
  return out
}

function formatInterval(seconds) {
  var s = Math.max(0, Math.round(seconds))
  if (s < MINUTE) return "<1m"
  if (s < HOUR) return Math.round(s / MINUTE) + "m"
  if (s < DAY) return Math.round(s / HOUR) + "h"

  var days = s / DAY
  if (days < 30) return Math.round(days) + "d"
  if (days < 365) return trimZero(days / 30) + "mo"
  return trimZero(days / 365) + "y"
}

function trimZero(value) {
  var text = value.toFixed(1)
  return text.slice(-2) === ".0" ? text.slice(0, -2) : text
}

// The local day this instant belongs to, with the 4am rollover applied.
function dayKey(now) {
  var d = new Date((now - ROLLOVER_HOUR * HOUR) * 1000)
  var month = d.getMonth() + 1
  var day = d.getDate()
  return d.getFullYear() + "-" + (month < 10 ? "0" : "") + month + "-" + (day < 10 ? "0" : "") + day
}

// --------------------------------------------------------------------- deck

// Cards are identified by a hash of their front, not by position, so
// reordering the file or fixing a typo on the back keeps a card's history.
// Editing the front is deliberately a new card: the question changed, and its
// old schedule was earned answering a different one.
function hashId(text) {
  var h = 0x811c9dc5
  for (var i = 0; i < text.length; i++) {
    h ^= text.charCodeAt(i)
    h = (h + ((h << 1) + (h << 4) + (h << 7) + (h << 8) + (h << 24))) >>> 0
  }
  return ("0000000" + h.toString(16)).slice(-8)
}

function text(value) {
  return value === undefined || value === null ? "" : String(value).trim()
}

// Accepts either a bare array or `{ "cards": [...] }`, because both are things
// a person plausibly types into a deck file. Entries missing a front or a back
// are dropped rather than shown as blank cards, and the first id wins on a
// duplicate front so one deck cannot hold two schedules under one identity.
function parseDeck(raw) {
  var data
  try {
    data = JSON.parse(raw || "")
  } catch (e) {
    return { cards: [], error: "Deck is not valid JSON" }
  }

  var list = Array.isArray(data) ? data : (data && Array.isArray(data.cards) ? data.cards : null)
  if (!list) return { cards: [], error: "Deck has no cards array" }

  var cards = []
  var seen = {}
  for (var i = 0; i < list.length; i++) {
    var entry = list[i]
    if (!entry || typeof entry !== "object") continue

    var front = text(entry.front)
    var back = text(entry.back)
    if (!front || !back) continue

    var id = text(entry.id) || hashId(front)
    if (seen[id]) continue
    seen[id] = true

    cards.push({
      id: id,
      front: front,
      back: back,
      tags: Array.isArray(entry.tags) ? entry.tags.map(text).filter(Boolean) : []
    })
  }

  return { cards: cards, error: "" }
}

// A tag is written twice — once in the deck, once in shell.json — and those
// two are typed months apart, so matching ignores case and duplicates.
function normalizeTags(wanted) {
  var out = []
  if (wanted === undefined || wanted === null) return out

  var list = Array.isArray(wanted) ? wanted : [wanted]
  for (var i = 0; i < list.length; i++) {
    var t = text(list[i]).toLowerCase()
    if (t && out.indexOf(t) === -1) out.push(t)
  }
  return out
}

// Narrowing a session to part of a deck is what makes a card's tags worth
// carrying. No filter means the whole deck; with one, a card is kept if it
// carries any of the wanted tags, so ["omarchy", "spanish"] is a union rather
// than a card needing both.
function filterByTags(cards, wanted) {
  var want = normalizeTags(wanted)
  if (!want.length) return cards || []

  var kept = []
  var list = cards || []
  for (var i = 0; i < list.length; i++) {
    var tags = list[i].tags || []
    for (var j = 0; j < tags.length; j++) {
      if (want.indexOf(text(tags[j]).toLowerCase()) !== -1) {
        kept.push(list[i])
        break
      }
    }
  }
  return kept
}

// The one-line state summary above the card. Both surfaces render it, so it is
// written once here rather than twice in QML.
function sectionLabel(phase, state, tags) {
  var head
  if (phase !== "reviewing") head = "SESSION"
  else if (state.phase === "new") head = "NEW"
  else if (state.phase === "learning") head = "LEARNING"
  else if (state.phase === "relearning")
    head = "RELEARNING  ·  " + state.lapses + " lapse" + (state.lapses === 1 ? "" : "s")
  else
    head = "REVIEW  ·  " + formatInterval(state.interval) + "  ·  ease " + (state.ease / 1000).toFixed(2)

  var want = normalizeTags(tags)
  return want.length ? head + "  ·  #" + want.join(" #") : head
}

function emptyProgress() {
  return { day: "", introduced: 0, reviews: {} }
}

function parseProgress(raw) {
  var progress = emptyProgress()
  try {
    var data = JSON.parse(raw || "{}")
    if (!data || typeof data !== "object") return progress

    progress.day = text(data.day)
    progress.introduced = Math.max(0, Math.round(num(data.introduced, 0)))

    if (data.reviews && typeof data.reviews === "object") {
      for (var id in data.reviews) {
        if (!Object.prototype.hasOwnProperty.call(data.reviews, id)) continue
        progress.reviews[id] = normalizeState(data.reviews[id])
      }
    }
  } catch (e) {
    // A corrupt progress file costs scheduling history, not a working panel.
  }
  return progress
}

// The new-card allowance is per study day, so a stale counter has to be
// cleared before it is read rather than when it was written — the shell may
// have been running since yesterday.
function rollDay(progress, now) {
  var today = dayKey(now)
  if (progress.day === today) return progress
  return { day: today, introduced: 0, reviews: progress.reviews }
}

function stateFor(progress, id) {
  return normalizeState(progress.reviews ? progress.reviews[id] : null)
}

// The queue for right now: everything already due, soonest first, then as many
// unseen cards as the day's allowance still permits. Reviews come before new
// cards because a card you are about to forget is worth more than one you have
// never seen.
function buildQueue(cards, progress, now, newPerDay) {
  var rolled = rollDay(progress || emptyProgress(), now)
  var limit = Math.max(0, Math.round(num(newPerDay, 20)))
  var remaining = Math.max(0, limit - rolled.introduced)

  var due = []
  var fresh = []

  for (var i = 0; i < cards.length; i++) {
    var card = cards[i]
    var s = stateFor(rolled, card.id)
    if (s.phase === "new") {
      if (fresh.length < remaining) fresh.push(card.id)
    } else if (s.due <= now) {
      due.push({ id: card.id, due: s.due })
    }
  }

  due.sort(function(a, b) { return a.due - b.due })

  var queue = []
  for (var d = 0; d < due.length; d++) queue.push(due[d].id)
  return queue.concat(fresh)
}

// How many answers back you can walk. Deep enough that a misgrade noticed a
// few cards later is still recoverable, bounded so a long session does not
// accumulate snapshots without limit.
var UNDO_DEPTH = 25

// Put a card at the front of the queue, inserting it if the rebuild dropped
// it. Undo uses this: the card you just took back has to be the next thing you
// see, wherever the scheduler would otherwise have placed it.
function promote(queue, id) {
  var list = queue || []
  if (!id) return list.slice()

  var out = [id]
  for (var i = 0; i < list.length; i++)
    if (list[i] !== id) out.push(list[i])
  return out
}

// Headline numbers for the bar and the panel. `waiting` is a card in learning
// that is not due yet — the reason a session can be empty and still unfinished.
function counts(cards, progress, now, newPerDay) {
  var rolled = rollDay(progress || emptyProgress(), now)
  var limit = Math.max(0, Math.round(num(newPerDay, 20)))
  var remaining = Math.max(0, limit - rolled.introduced)

  var out = {
    total: cards.length,
    due: 0,
    learning: 0,
    fresh: 0,
    waiting: 0,
    nextDue: 0
  }

  for (var i = 0; i < cards.length; i++) {
    var s = stateFor(rolled, cards[i].id)

    if (s.phase === "new") {
      out.fresh++
      continue
    }
    if (s.due <= now) {
      out.due++
      if (s.phase === "learning" || s.phase === "relearning") out.learning++
      continue
    }
    if (s.phase === "learning" || s.phase === "relearning") out.waiting++
    if (!out.nextDue || s.due < out.nextDue) out.nextDue = s.due
  }

  out.fresh = Math.min(out.fresh, remaining)
  out.pending = out.due + out.fresh
  return out
}

// ------------------------------------------------------------------ file I/O
//
// Both files live in directories the user — and anything else running as them
// — can write, and the shell reading them is a long-lived process shared by
// every panel. So they are treated as hostile input in both directions rather
// than opened with the plain file API.
//
// Reading: refuse symlinks and anything that is not a regular file, open
// non-blocking so a planted FIFO cannot stall the shell, and stop at 256 KiB
// so an inflated file cannot be pulled into memory. Empty output means "no
// file", which both parsers already treat as empty.
//
// $1 = path to read.
var READ_SH = [
  'f="$1"',
  '[ -L "$f" ] && exit 0',
  '[ -f "$f" ] || exit 0',
  'exec dd if="$f" iflag=nofollow,nonblock bs=262144 count=1 2>/dev/null'
].join("\n")

// Writing: the document arrives on stdin, so nothing about it is interpolated
// into the shell and no amount of quoting in a card can escape. It is built in
// a fresh 0600 file that mktemp creates exclusively, then renamed onto the
// destination — rename replaces a symlink instead of following it, so the
// write cannot be redirected elsewhere, and a reader sees either the whole old
// document or the whole new one.
//
// $1 = directory, $2 = file name within it.
var WRITE_SH = [
  'd="$1"; f="$2"',
  'case "$f" in ""|.|..|*/*) exit 64;; esac',
  'mkdir -p -m 700 "$d" || exit 65',
  't=$(mktemp "$d/.omanki.XXXXXX") || exit 66',
  'chmod 600 "$t" || { rm -f "$t"; exit 67; }',
  'cat > "$t" || { rm -f "$t"; exit 68; }',
  'mv -f "$t" "$d/$f" || { rm -f "$t"; exit 69; }'
].join("\n")

function serializeProgress(progress) {
  var p = progress || emptyProgress()
  return JSON.stringify({
    day: text(p.day),
    introduced: Math.max(0, Math.round(num(p.introduced, 0))),
    reviews: p.reviews || {}
  }) + "\n"
}

// Both surfaces resolve their settings the same way, so the resolution lives
// here rather than twice in QML. `~` is the only thing worth expanding: a deck
// path is hand-typed into shell.json, and a leading ~ is what a person writes.
// Anything else is passed through exactly as given.
function resolveDeck(configured, home) {
  var path = text(configured)
  if (!path) return home + "/.local/share/omanki/cards.json"
  if (path === "~") return home
  if (path.slice(0, 2) === "~/") return home + path.slice(1)
  return path
}

// A typo in shell.json should leave the plugin usable, not stop it introducing
// cards, so anything unparseable falls back to the default rather than to zero.
function sanePerDay(value) {
  var n = parseInt(value, 10)
  return (isFinite(n) && n >= 0) ? n : 20
}

// Our own entry in shell.json, wherever it lives. A plugin placed in the bar
// is configured on its bar.layout entry; one that is only enabled is
// configured on its top-level plugins[] entry. This mirrors the shell's own
// findEntryLocation so a setting is read from the same place either way.
function findEntry(config, id) {
  if (!config || !id) return {}

  var layout = config.bar && config.bar.layout
  if (layout) {
    var sections = ["left", "center", "right"]
    for (var s = 0; s < sections.length; s++) {
      var arr = layout[sections[s]]
      if (!Array.isArray(arr)) continue
      for (var i = 0; i < arr.length; i++)
        if (arr[i] && arr[i].id === id) return arr[i]
    }
  }

  if (Array.isArray(config.plugins)) {
    for (var p = 0; p < config.plugins.length; p++)
      if (config.plugins[p] && config.plugins[p].id === id) return config.plugins[p]
  }

  return {}
}
