// Scheduler and deck tests for the omanki plugin.
//
//   node tests/scheduler.test.mjs
//
// Anki.js is deliberately free of QML types so the scheduling rules can be
// exercised under plain node. Anything that needs a running shell is not
// tested here, apart from the two file-I/O snippets, which are plain sh and
// are run as such.

import { execFileSync, spawnSync } from "node:child_process"
import { lstatSync, mkdtempSync, readFileSync, statSync, symlinkSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"

const here = dirname(fileURLToPath(import.meta.url))
const src = readFileSync(join(here, "..", "Anki.js"), "utf8")

const EXPORTS = [
  "MINUTE", "HOUR", "DAY", "GRADES", "LEARNING_STEPS", "RELEARNING_STEPS",
  "STARTING_EASE", "MIN_EASE", "MAX_EASE", "MAX_INTERVAL",
  "newState", "normalizeState", "grade", "previewIntervals", "formatInterval",
  "dayKey", "hashId", "parseDeck", "emptyProgress", "parseProgress", "rollDay",
  "stateFor", "buildQueue", "counts", "serializeProgress", "findEntry",
  "resolveDeck", "sanePerDay",
  "READ_SH", "WRITE_SH",
]
const G = {}
new Function("exports", `${src}\nfor (const k of ${JSON.stringify(EXPORTS)}) exports[k] = eval(k)`)(G)

let pass = 0, fail = 0
const t = (name, cond) => {
  if (cond) { pass++; console.log("  ok   " + name) }
  else { fail++; console.log("  FAIL " + name) }
}
const group = (name) => console.log("\n" + name)

const NOW = 1_700_000_000
const { DAY, MINUTE } = G

group("a new card walks the learning steps")
{
  const fresh = G.newState()
  t("starts new with no interval", fresh.phase === "new" && fresh.interval === 0)

  const first = G.grade(fresh, "good", NOW)
  t("good moves to the second step, not to review",
    first.phase === "learning" && first.step === 1 && first.due === NOW + 10 * MINUTE)

  const graduated = G.grade(first, "good", NOW)
  t("good again graduates at one day",
    graduated.phase === "review" && graduated.interval === DAY && graduated.due === NOW + DAY)

  t("again restarts the steps",
    G.grade(first, "again", NOW).step === 0 && G.grade(first, "again", NOW).due === NOW + MINUTE)
  t("hard repeats the current step",
    G.grade(first, "hard", NOW).step === 1 && G.grade(first, "hard", NOW).due === NOW + 10 * MINUTE)
  t("easy graduates straight to four days",
    G.grade(fresh, "easy", NOW).phase === "review" && G.grade(fresh, "easy", NOW).interval === 4 * DAY)
  t("learning never touches ease", first.ease === G.STARTING_EASE && graduated.ease === G.STARTING_EASE)
  t("every answer counts as a rep", first.reps === 1 && graduated.reps === 2)
}

group("review intervals grow by ease")
{
  const review = { phase: "review", due: NOW, interval: 10 * DAY, ease: 2500, reps: 5, lapses: 0, step: 0 }

  t("good multiplies by the ease factor", G.grade(review, "good", NOW).interval === 25 * DAY)
  t("good leaves ease alone", G.grade(review, "good", NOW).ease === 2500)
  t("hard grows more slowly than good",
    G.grade(review, "hard", NOW).interval < G.grade(review, "good", NOW).interval)
  t("hard costs ease", G.grade(review, "hard", NOW).ease === 2350)
  t("easy grows faster than good",
    G.grade(review, "easy", NOW).interval > G.grade(review, "good", NOW).interval)
  t("easy earns ease", G.grade(review, "easy", NOW).ease === 2650)
  t("due follows the new interval", G.grade(review, "good", NOW).due === NOW + 25 * DAY)
}

group("a passing grade always moves the card further out")
{
  // Ease floored and a one-day interval: every multiplier rounds back to the
  // interval it started from, and without a guard the card sticks there.
  const stuck = { phase: "review", due: NOW, interval: DAY, ease: G.MIN_EASE, reps: 9, lapses: 4, step: 0 }
  for (const g of ["hard", "good", "easy"])
    t(`${g} exceeds the previous interval`, G.grade(stuck, g, NOW).interval > stuck.interval)
}

group("lapses")
{
  const review = { phase: "review", due: NOW, interval: 20 * DAY, ease: 2500, reps: 8, lapses: 1, step: 0 }
  const lapsed = G.grade(review, "again", NOW)

  t("again enters relearning", lapsed.phase === "relearning")
  t("again counts a lapse", lapsed.lapses === 2)
  t("again costs 200 ease", lapsed.ease === 2300)
  t("again halves the interval", lapsed.interval === 10 * DAY)
  t("again is due in ten minutes", lapsed.due === NOW + 10 * MINUTE)

  const recovered = G.grade(lapsed, "good", NOW)
  t("leaving relearning restores the halved interval, not a fresh day",
    recovered.phase === "review" && recovered.interval === 10 * DAY)
  t("again inside relearning stays there",
    G.grade(lapsed, "again", NOW).phase === "relearning")
  t("easy inside relearning leaves immediately",
    G.grade(lapsed, "easy", NOW).phase === "review")
}

group("ease and interval stay in range")
{
  let s = { phase: "review", due: NOW, interval: DAY, ease: G.MIN_EASE, reps: 1, lapses: 0, step: 0 }
  for (let i = 0; i < 20; i++) s = G.grade({ ...s, phase: "review" }, "again", NOW)
  t("ease has a floor", s.ease === G.MIN_EASE)

  let e = { phase: "review", due: NOW, interval: DAY, ease: G.MAX_EASE, reps: 1, lapses: 0, step: 0 }
  for (let i = 0; i < 20; i++) e = { ...G.grade(e, "easy", NOW) }
  t("ease has a ceiling", e.ease === G.MAX_EASE)
  t("interval has a ceiling", e.interval <= G.MAX_INTERVAL)
}

group("hostile state is coerced, never trusted")
{
  t("a nonsense phase becomes a new card", G.normalizeState({ phase: "wat" }).phase === "new")
  t("a null state becomes a new card", G.normalizeState(null).phase === "new")
  t("NaN interval becomes zero", G.normalizeState({ phase: "review", interval: "abc" }).interval === 0)
  t("a negative due is clamped", G.normalizeState({ phase: "review", due: -99 }).due === 0)
  t("an out-of-range ease is clamped", G.normalizeState({ phase: "review", ease: 99999 }).ease === G.MAX_EASE)
  t("an out-of-range step is clamped",
    G.normalizeState({ phase: "learning", step: 47 }).step === G.LEARNING_STEPS.length - 1)
  t("an unknown grade is a no-op",
    G.grade(G.newState(), "excellent", NOW).phase === "new")
}

group("interval labels")
{
  t("seconds", G.formatInterval(30) === "<1m")
  t("minutes", G.formatInterval(10 * MINUTE) === "10m")
  t("hours", G.formatInterval(5 * 3600) === "5h")
  t("days", G.formatInterval(3 * DAY) === "3d")
  t("months", G.formatInterval(60 * DAY) === "2mo")
  t("years", G.formatInterval(730 * DAY) === "2y")

  const preview = G.previewIntervals(G.newState(), NOW)
  t("every grade is priced", G.GRADES.every((g) => preview[g].length > 0))
  t("previewing does not schedule anything", G.newState().reps === 0)
}

group("deck parsing")
{
  const deck = G.parseDeck(JSON.stringify({
    cards: [
      { front: " Capital of France ", back: "Paris" },
      { front: "", back: "dropped" },
      { front: "no back", back: "  " },
      { front: "Capital of France", back: "duplicate" },
      { front: "Tagged", back: "yes", tags: ["geo", 7] },
      "not an object",
    ],
  }))

  t("two usable cards survive", deck.cards.length === 2)
  t("whitespace is trimmed", deck.cards[0].front === "Capital of France")
  t("a duplicate front is dropped", deck.cards.filter((c) => c.front === "Capital of France").length === 1)
  t("tags are coerced to strings", deck.cards[1].tags.join(",") === "geo,7")
  t("a bare array is accepted", G.parseDeck('[{"front":"a","back":"b"}]').cards.length === 1)
  t("broken JSON reports an error", G.parseDeck("{oops").error.length > 0)
  t("a missing cards array reports an error", G.parseDeck('{"deck":[]}').error.length > 0)

  t("the id follows the front, not the position",
    G.parseDeck('[{"front":"a","back":"1"},{"front":"b","back":"2"}]').cards[1].id ===
    G.parseDeck('[{"front":"b","back":"2"},{"front":"a","back":"1"}]').cards[0].id)
  t("editing the back keeps the id",
    G.parseDeck('[{"front":"a","back":"1"}]').cards[0].id ===
    G.parseDeck('[{"front":"a","back":"CHANGED"}]').cards[0].id)
  t("editing the front is a new card",
    G.parseDeck('[{"front":"a","back":"1"}]').cards[0].id !==
    G.parseDeck('[{"front":"A","back":"1"}]').cards[0].id)
  t("an explicit id wins", G.parseDeck('[{"id":"mine","front":"a","back":"1"}]').cards[0].id === "mine")
}

group("the queue")
{
  const cards = G.parseDeck(JSON.stringify([
    { front: "one", back: "1" },
    { front: "two", back: "2" },
    { front: "three", back: "3" },
  ])).cards
  const [a, b, c] = cards.map((x) => x.id)
  const today = G.dayKey(NOW)

  const progress = {
    day: today,
    introduced: 0,
    reviews: {
      [a]: { phase: "review", due: NOW - 100, interval: 5 * DAY, ease: 2500, reps: 3, lapses: 0, step: 0 },
      [b]: { phase: "review", due: NOW + 5 * DAY, interval: 5 * DAY, ease: 2500, reps: 3, lapses: 0, step: 0 },
    },
  }

  const queue = G.buildQueue(cards, progress, NOW, 20)
  t("a due card is queued", queue.includes(a))
  t("a card due in the future is not", !queue.includes(b))
  t("an unseen card is queued", queue.includes(c))
  t("due cards come before new ones", queue.indexOf(a) < queue.indexOf(c))

  t("the new-card allowance is respected",
    G.buildQueue(cards, { day: today, introduced: 0, reviews: {} }, NOW, 1).length === 1)
  t("cards introduced today count against it",
    G.buildQueue(cards, { day: today, introduced: 2, reviews: {} }, NOW, 2).length === 0)
  t("yesterday's count does not",
    G.buildQueue(cards, { day: "1999-01-01", introduced: 99, reviews: {} }, NOW, 2).length === 2)

  const overdue = {
    day: today,
    introduced: 0,
    reviews: {
      [a]: { phase: "review", due: NOW - 10, interval: DAY, ease: 2500, reps: 1, lapses: 0, step: 0 },
      [b]: { phase: "review", due: NOW - 9999, interval: DAY, ease: 2500, reps: 1, lapses: 0, step: 0 },
    },
  }
  t("the most overdue card comes first", G.buildQueue(cards, overdue, NOW, 0)[0] === b)

  const stats = G.counts(cards, progress, NOW, 20)
  t("counts the due card", stats.due === 1)
  t("counts the new card", stats.fresh === 1)
  t("counts the whole deck", stats.total === 3)
  t("pending is due plus new", stats.pending === 2)
  t("caps new by the day's allowance", G.counts(cards, progress, NOW, 0).fresh === 0)
  t("reports when the next card is due", stats.nextDue === NOW + 5 * DAY)

  const learning = {
    day: today,
    introduced: 1,
    reviews: { [a]: { phase: "learning", due: NOW + 60, interval: 0, ease: 2500, reps: 1, lapses: 0, step: 0 } },
  }
  t("a learning card not yet due is waiting, not due",
    G.counts(cards, learning, NOW, 0).waiting === 1 && G.counts(cards, learning, NOW, 0).due === 0)
}

group("the study day rolls over at 4am, not midnight")
{
  const at = (h, m) => Math.floor(new Date(2026, 0, 15, h, m, 0).getTime() / 1000)
  t("1am still belongs to the previous day", G.dayKey(at(1, 0)) === "2026-01-14")
  t("3:59am still does", G.dayKey(at(3, 59)) === "2026-01-14")
  t("4am starts the new day", G.dayKey(at(4, 0)) === "2026-01-15")
  t("the afternoon is unsurprising", G.dayKey(at(15, 0)) === "2026-01-15")
}

group("progress round-trips")
{
  const progress = {
    day: "2026-01-15",
    introduced: 3,
    reviews: { abc: { phase: "review", due: NOW, interval: DAY, ease: 2500, reps: 1, lapses: 0, step: 0 } },
  }
  const back = G.parseProgress(G.serializeProgress(progress))
  t("day survives", back.day === progress.day)
  t("introduced survives", back.introduced === 3)
  t("card state survives", back.reviews.abc.interval === DAY)
  t("a corrupt file is empty, not fatal", G.parseProgress("{not json").introduced === 0)
  t("an absent file is empty", G.parseProgress("").day === "")
  t("an unknown card reads as new", G.stateFor(progress, "nope").phase === "new")
}

group("settings are read from wherever the plugin is configured")
{
  const id = "yamz8.omanki"
  t("from the bar layout",
    G.findEntry({ bar: { layout: { right: [{ id, newPerDay: 5 }] } } }, id).newPerDay === 5)
  t("from the plugins list",
    G.findEntry({ plugins: [{ id, newPerDay: 7 }] }, id).newPerDay === 7)
  t("absent is an empty object", Object.keys(G.findEntry({}, id)).length === 0)
}

group("settings resolution is shared by both surfaces")
{
  const HOME = "/home/yamz8"
  t("an unset deck falls back to the default",
    G.resolveDeck("", HOME) === HOME + "/.local/share/omanki/cards.json")
  t("an undefined deck falls back too",
    G.resolveDeck(undefined, HOME) === HOME + "/.local/share/omanki/cards.json")
  t("a leading ~/ expands", G.resolveDeck("~/notes/spanish.json", HOME) === HOME + "/notes/spanish.json")
  t("a bare ~ expands", G.resolveDeck("~", HOME) === HOME)
  t("an absolute path is left alone", G.resolveDeck("/srv/decks/a.json", HOME) === "/srv/decks/a.json")
  t("a ~ that is not a home reference is left alone",
    G.resolveDeck("/tmp/~weird.json", HOME) === "/tmp/~weird.json")
  t("whitespace is trimmed", G.resolveDeck("  ~/a.json  ", HOME) === HOME + "/a.json")

  t("a sane allowance is kept", G.sanePerDay(5) === 5)
  t("zero is a real choice, not a fallback", G.sanePerDay(0) === 0)
  t("a numeric string is accepted", G.sanePerDay("7") === 7)
  t("a typo falls back to the default", G.sanePerDay("lots") === 20)
  t("undefined falls back to the default", G.sanePerDay(undefined) === 20)
  t("a negative falls back to the default", G.sanePerDay(-3) === 20)
}

// --------------------------------------------------------------- file I/O
//
// READ_SH and WRITE_SH are plain sh, so they are run as plain sh. What is
// being checked is the hardening: that neither can be pointed at a file it was
// not meant to touch.

group("reading refuses what it should")
{
  const dir = mkdtempSync(join(tmpdir(), "omanki-"))
  const read = (path) =>
    execFileSync("sh", ["-c", G.READ_SH, "omanki", path], { encoding: "utf8" })

  writeFileSync(join(dir, "deck.json"), '{"cards":[]}\n')
  t("a regular file is read", read(join(dir, "deck.json")).trim() === '{"cards":[]}')
  t("a missing file is empty, not an error", read(join(dir, "nope.json")) === "")

  writeFileSync(join(dir, "secret"), "not yours\n")
  symlinkSync(join(dir, "secret"), join(dir, "link.json"))
  t("a symlink is refused", read(join(dir, "link.json")) === "")

  t("a directory is refused", read(dir) === "")

  writeFileSync(join(dir, "big.json"), "x".repeat(500_000))
  t("an oversized file is truncated, not swallowed whole",
    read(join(dir, "big.json")).length === 262_144)
}

group("writing cannot be redirected")
{
  const dir = mkdtempSync(join(tmpdir(), "omanki-"))
  const write = (target, name, doc) =>
    spawnSync("sh", ["-c", G.WRITE_SH, "omanki", target, name], { input: doc, encoding: "utf8" })

  const doc = G.serializeProgress({ day: "2026-01-15", introduced: 1, reviews: {} })
  const ok = write(join(dir, "state"), "omanki.json", doc)
  t("a normal write succeeds", ok.status === 0)
  t("the document lands intact",
    readFileSync(join(dir, "state", "omanki.json"), "utf8") === doc)
  t("the file is private", (statSync(join(dir, "state", "omanki.json")).mode & 0o777) === 0o600)

  t("a path separator in the name is refused", write(dir, "../escape.json", doc).status === 64)
  t("an empty name is refused", write(dir, "", doc).status === 64)

  // The real defence: a planted symlink at the destination is replaced, not
  // followed, so a write cannot be aimed at a file elsewhere.
  const outside = join(dir, "outside.json")
  writeFileSync(outside, "untouched\n")
  symlinkSync(outside, join(dir, "state", "planted.json"))
  t("a planted symlink is replaced, not followed",
    write(join(dir, "state"), "planted.json", doc).status === 0 &&
    readFileSync(outside, "utf8") === "untouched\n" &&
    !lstatSync(join(dir, "state", "planted.json")).isSymbolicLink())

  // Cards are user text and end up inside the document; nothing about it is
  // interpolated into the shell, so quoting in a card cannot escape.
  const nasty = JSON.stringify({ day: "x", introduced: 0, reviews: { "a\"; rm -rf /; #": G.newState() } })
  const hostile = write(join(dir, "state"), "hostile.json", nasty)
  t("a document full of shell metacharacters is written verbatim",
    hostile.status === 0 && readFileSync(join(dir, "state", "hostile.json"), "utf8") === nasty)
}

console.log(`\n${pass} passed, ${fail} failed`)
process.exit(fail ? 1 : 0)
