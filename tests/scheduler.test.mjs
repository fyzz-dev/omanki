// Scheduler and deck tests for the omanki plugin.
//
//   node tests/scheduler.test.mjs
//
// Anki.js is deliberately free of QML types so the scheduling rules can be
// exercised under plain node. Anything that needs a running shell is not
// tested here, apart from the two file-I/O snippets, which are plain sh and
// are run as such.

import { execFileSync, spawnSync } from "node:child_process"
import { chmodSync, lstatSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync,
         statSync, symlinkSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"

const here = dirname(fileURLToPath(import.meta.url))
const src = readFileSync(join(here, "..", "Anki.js"), "utf8")

const EXPORTS = [
  "MINUTE", "HOUR", "DAY", "GRADES", "LEARNING_STEPS", "RELEARNING_STEPS",
  "STARTING_EASE", "MIN_EASE", "MAX_EASE", "MAX_INTERVAL",
  "newState", "normalizeState", "grade", "previewIntervals", "formatInterval",
  "dayKey", "hashId", "parseDeck", "emptyProgress", "parseProgress",
  "stateFor", "buildQueue", "counts", "serializeProgress", "findEntry",
  "mergeProgress", "introducedToday", "reviewsToday", "remainingToday",
  "deckStats", "percent", "appendCard", "dirOf", "baseOf", "MATURE_INTERVAL",
  "resolveDeck", "sanePerDay", "normalizeTags", "filterByTags", "sectionLabel", "promote", "UNDO_DEPTH",
  "READ_SH", "WRITE_SH", "relativeToHome",
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

group("tag filtering")
{
  const deck = G.parseDeck(JSON.stringify([
    { front: "a", back: "1", tags: ["omarchy", "cli"] },
    { front: "b", back: "2", tags: ["Spanish"] },
    { front: "c", back: "3" },
    { front: "d", back: "4", tags: ["cli"] },
  ])).cards

  t("no filter keeps the whole deck", G.filterByTags(deck, []).length === 4)
  t("an absent filter keeps the whole deck", G.filterByTags(deck, undefined).length === 4)
  t("a filter keeps only matching cards", G.filterByTags(deck, ["cli"]).map(c => c.front).join("") === "ad")
  t("an untagged card is excluded by any filter", !G.filterByTags(deck, ["cli"]).some(c => c.front === "c"))
  t("several tags are a union, not an intersection",
    G.filterByTags(deck, ["omarchy", "spanish"]).map(c => c.front).join("") === "ab")
  t("matching ignores case on both sides", G.filterByTags(deck, ["SPANISH"]).length === 1)
  t("a bare string works like a one-element list", G.filterByTags(deck, "cli").length === 2)
  t("a filter matching nothing yields nothing", G.filterByTags(deck, ["nope"]).length === 0)
  t("filtering does not mutate the deck", deck.length === 4)

  t("tags are lowercased and de-duplicated",
    G.normalizeTags(["CLI", "cli", " Cli "]).join(",") === "cli")
  t("empty entries are dropped", G.normalizeTags(["", "  ", "a"]).join(",") === "a")
  t("null is an empty filter", G.normalizeTags(null).length === 0)
}

group("the section label")
{
  const review = { phase: "review", due: NOW, interval: 10 * DAY, ease: 2500, reps: 5, lapses: 0, step: 0 }
  t("a new card", G.sectionLabel("reviewing", { phase: "new" }, []) === "NEW")
  t("not reviewing", G.sectionLabel("done", { phase: "new" }, []) === "SESSION")
  t("a review card shows interval and ease",
    G.sectionLabel("reviewing", review, []) === "REVIEW  ·  10d  ·  ease 2.50")
  t("a lapsed card counts its lapses",
    G.sectionLabel("reviewing", { phase: "relearning", lapses: 1 }, []).indexOf("1 lapse") !== -1)
  t("plural lapses",
    G.sectionLabel("reviewing", { phase: "relearning", lapses: 3 }, []).indexOf("3 lapses") !== -1)
  t("an active filter is shown", G.sectionLabel("reviewing", { phase: "new" }, ["cli"]) === "NEW  ·  #cli")
  t("no filter adds nothing", G.sectionLabel("reviewing", { phase: "new" }, []).indexOf("#") === -1)
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
    G.buildQueue(cards, G.emptyProgress(), NOW, 1).length === 1)

  // Two cards dated today, so the allowance of two is already spent.
  const spentToday = { reviews: {
    [a]: { phase: "review", due: NOW + DAY, interval: DAY, ease: 2500, reps: 1, lapses: 0, step: 0, firstDay: today },
    [b]: { phase: "review", due: NOW + DAY, interval: DAY, ease: 2500, reps: 1, lapses: 0, step: 0, firstDay: today },
  } }
  t("cards introduced today count against it",
    G.buildQueue(cards, spentToday, NOW, 2).length === 0)
  t("the same cards dated yesterday do not", (() => {
    const yesterday = JSON.parse(JSON.stringify(spentToday))
    for (const id of Object.keys(yesterday.reviews)) yesterday.reviews[id].firstDay = "1999-01-01"
    return G.buildQueue(cards, yesterday, NOW, 2).length === 1
  })())
  t("introducedToday counts only today's", G.introducedToday(spentToday, NOW) === 2)
  t("an undated card counts as never introduced",
    G.introducedToday({ reviews: { x: G.newState() } }, NOW) === 0)

  const overdue = {
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
    reviews: { [a]: { phase: "learning", due: NOW + 60, interval: 0, ease: 2500, reps: 1, lapses: 0, step: 0 } },
  }
  t("a learning card not yet due is waiting, not due",
    G.counts(cards, learning, NOW, 0).waiting === 1 && G.counts(cards, learning, NOW, 0).due === 0)
}

group("promoting a card for undo")
{
  t("an already-queued card moves to the front",
    G.promote(["a", "b", "c"], "c").join(",") === "c,a,b")
  t("it is not duplicated", G.promote(["a", "b", "c"], "c").length === 3)
  t("a card the rebuild dropped is inserted",
    G.promote(["a", "b"], "z").join(",") === "z,a,b")
  t("the front card stays at the front", G.promote(["a", "b"], "a").join(",") === "a,b")
  t("an empty queue yields just the card", G.promote([], "a").join(",") === "a")
  t("no id leaves the queue alone", G.promote(["a", "b"], "").join(",") === "a,b")
  t("the original queue is not mutated", (() => {
    const q = ["a", "b", "c"]
    G.promote(q, "c")
    return q.join(",") === "a,b,c"
  })())

  t("undo depth is bounded", G.UNDO_DEPTH > 0 && G.UNDO_DEPTH <= 100)
}

group("undo restores what the answer changed")
{
  // The QML owns the stack, but the state arithmetic it puts back is this
  // module's: an answer must be reconstructible from the snapshot alone.
  const fresh = G.newState()
  const answered = G.grade(fresh, "good", NOW)
  t("an answer changes the state", answered.phase !== fresh.phase || answered.due !== fresh.due)
  t("grading never mutates the state handed in",
    fresh.phase === "new" && fresh.reps === 0 && fresh.due === 0)
  t("so the pre-answer state is still a faithful snapshot",
    JSON.stringify(fresh) === JSON.stringify(G.newState()))

  const review = { phase: "review", due: NOW, interval: 10 * DAY, ease: 2500, reps: 5, lapses: 0, step: 0 }
  const lapsed = G.grade(review, "again", NOW)
  t("a lapse changes ease and interval", lapsed.ease !== review.ease && lapsed.interval !== review.interval)
  t("and leaves the original untouched to restore from",
    review.ease === 2500 && review.interval === 10 * DAY && review.lapses === 0)
}

group("the daily review cap")
{
  const cards = G.parseDeck(JSON.stringify(
    Array.from({ length: 5 }, (_, i) => ({ front: "q" + i, back: "a" + i })))).cards
  const today = G.dayKey(NOW)

  // Five cards, all due, all first seen well before today.
  const due = { reviews: {} }
  for (const c of cards)
    due.reviews[c.id] = { phase: "review", due: NOW - 100, interval: 5 * DAY, ease: 2500,
                          reps: 3, lapses: 0, step: 0, updated: 0, firstDay: "1999-01-01" }

  t("no cap serves everything due", G.buildQueue(cards, due, NOW, 0, 0).length === 5)
  t("a cap trims the queue", G.buildQueue(cards, due, NOW, 0, 2).length === 2)
  t("counts agree with the queue", G.counts(cards, due, NOW, 0, 2).due === 2)
  t("what the cap holds back is reported separately", G.counts(cards, due, NOW, 0, 2).held === 3)
  t("nothing is held back without a cap", G.counts(cards, due, NOW, 0, 0).held === 0)

  t("the most overdue survive the trim", (() => {
    const spread = { reviews: {} }
    cards.forEach((c, i) => {
      spread.reviews[c.id] = { phase: "review", due: NOW - (100 - i * 10), interval: DAY,
                               ease: 2500, reps: 3, lapses: 0, step: 0, updated: 0, firstDay: "1999-01-01" }
    })
    return G.buildQueue(cards, spread, NOW, 0, 1)[0] === cards[0].id
  })())

  // Answering today spends the budget.
  const doneToday = JSON.parse(JSON.stringify(due))
  doneToday.reviews[cards[0].id].updated = NOW
  doneToday.reviews[cards[1].id].updated = NOW
  t("cards answered today count as reviews", G.reviewsToday(doneToday, NOW) === 2)
  t("a spent budget serves nothing", G.buildQueue(cards, doneToday, NOW, 0, 2).length === 0)

  t("a card introduced today is not also a review", (() => {
    const fresh = { reviews: { x: { phase: "learning", due: NOW, interval: 0, ease: 2500,
                                    reps: 1, lapses: 0, step: 0, updated: NOW, firstDay: today } } }
    return G.reviewsToday(fresh, NOW) === 0
  })())
  t("an unanswered card is not a review today", G.reviewsToday(due, NOW) === 0)

  t("remainingToday reports an uncapped budget as infinite",
    G.remainingToday(due, NOW, 20, 0).due === Infinity)
  t("and a spent one as zero", G.remainingToday(doneToday, NOW, 20, 2).due === 0)
}

group("deck statistics")
{
  const cards = G.parseDeck(JSON.stringify(
    Array.from({ length: 6 }, (_, i) => ({ front: "q" + i, back: "a" + i })))).cards
  const [a, b, c, d, e, f] = cards.map((x) => x.id)

  const progress = { reviews: {
    [a]: { phase: "review", due: NOW + 30 * DAY, interval: 30 * DAY, ease: 2600, reps: 9, lapses: 0, step: 0, updated: NOW, firstDay: "1999-01-01" },
    [b]: { phase: "review", due: NOW + 2 * DAY, interval: 2 * DAY, ease: 2400, reps: 4, lapses: 1, step: 0, updated: 0, firstDay: "1999-01-01" },
    [c]: { phase: "learning", due: NOW + 60, interval: 0, ease: 2500, reps: 1, lapses: 0, step: 0, updated: NOW, firstDay: G.dayKey(NOW) },
    [d]: { phase: "relearning", due: NOW + 600, interval: DAY, ease: 2300, reps: 7, lapses: 2, step: 0, updated: 0, firstDay: "1999-01-01" },
  } }

  const s = G.deckStats(cards, progress, NOW, 20, 0)
  t("counts the whole deck", s.total === 6)
  t("unanswered cards are new", s.fresh === 2)
  t("a long interval is mature", s.mature === 1)
  t("a short one is young", s.young === 1)
  t("learning and relearning are one bucket", s.learning === 2)
  t("the buckets account for every card", s.fresh + s.mature + s.young + s.learning === s.total)
  t("seen is the deck less the new", s.seen === 4)
  t("lapsed cards are counted once each", s.lapsed === 2)
  t("lapses are totalled", s.lapses === 3)
  t("average ease is over answered cards only", Math.abs(s.ease - 2.45) < 0.001)
  t("answered today is counted", s.answeredToday === 2)
  t("retention falls out of lapses over reps", Math.abs(s.retention - (1 - 3 / 21)) < 0.001)

  t("the forecast buckets by day", s.forecast[0] === 2 && s.forecast[2] === 1)
  t("the forecast spans a week", s.forecast.length === 7)
  t("cards beyond the week are not in it", s.forecast.reduce((x, y) => x + y, 0) === 3)

  const empty = G.deckStats([], G.emptyProgress(), NOW, 20, 0)
  t("an empty deck is all zeroes, not NaN", empty.total === 0 && empty.ease === 0 && empty.retention === 0)
  t("percent formats a fraction", G.percent(0.8) === "80%")
  t("percent clamps", G.percent(9) === "100%" && G.percent(-1) === "0%")
}

group("adding a card to the deck")
{
  const deck = JSON.stringify({ cards: [{ front: "a", back: "1", note: "kept" }] }, null, 2)

  const added = G.appendCard(deck, "b", "2", ["x"])
  t("succeeds", added.error === "")
  t("the new card is appended", JSON.parse(added.raw).cards.length === 2)
  t("the new card holds what was typed", (() => {
    const card = JSON.parse(added.raw).cards[1]
    return card.front === "b" && card.back === "2" && card.tags.join() === "x"
  })())
  t("fields the plugin knows nothing about survive",
    JSON.parse(added.raw).cards[0].note === "kept")
  t("existing cards keep their order", JSON.parse(added.raw).cards[0].front === "a")
  t("input is trimmed", JSON.parse(G.appendCard(deck, "  c  ", "  3  ").raw).cards[1].front === "c")
  t("no tags means no tags key", JSON.parse(G.appendCard(deck, "c", "3").raw).cards[1].tags === undefined)
  t("a bare array deck stays a bare array",
    Array.isArray(JSON.parse(G.appendCard('[{"front":"a","back":"1"}]', "b", "2").raw)))
  t("an absent deck is created", JSON.parse(G.appendCard("", "a", "1").raw).cards.length === 1)

  t("a missing front is refused", G.appendCard(deck, "", "2").error.length > 0)
  t("a missing back is refused", G.appendCard(deck, "b", "  ").error.length > 0)
  t("a duplicate front is refused", G.appendCard(deck, "a", "different").error.length > 0)
  t("a duplicate is refused even against an explicit id",
    G.appendCard(JSON.stringify({ cards: [{ id: G.hashId("z"), front: "other", back: "1" }] }), "z", "2").error.length > 0)

  // The one unrecoverable thing it could do is overwrite a deck it failed to
  // parse, so a broken deck must come back untouched.
  const broken = "{ not json"
  const refused = G.appendCard(broken, "b", "2")
  t("a broken deck is refused", refused.error.length > 0)
  t("and handed back byte for byte", refused.raw === broken)
  t("a deck with no cards array is refused", G.appendCard('{"x":1}', "b", "2").error.length > 0)
}

group("splitting a deck path for the writer")
{
  t("directory", G.dirOf("/home/u/.local/share/omanki/cards.json") === "/home/u/.local/share/omanki")
  t("file name", G.baseOf("/home/u/.local/share/omanki/cards.json") === "cards.json")
  t("a bare name has no directory", G.baseOf("cards.json") === "cards.json")
  t("a root-level file keeps a valid directory", G.dirOf("/cards.json") === "/")
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
    reviews: { abc: { phase: "review", due: NOW, interval: DAY, ease: 2500, reps: 1, lapses: 0, step: 0, updated: NOW, firstDay: "2026-01-15" } },
  }
  const back = G.parseProgress(G.serializeProgress(progress))
  t("card state survives", back.reviews.abc.interval === DAY)
  t("the change stamp survives", back.reviews.abc.updated === NOW)
  t("the introduction date survives", back.reviews.abc.firstDay === "2026-01-15")
  t("a corrupt file is empty, not fatal", Object.keys(G.parseProgress("{not json").reviews).length === 0)
  t("an absent file is empty", Object.keys(G.parseProgress("").reviews).length === 0)
  t("a document written before the tally was derived still loads",
    G.parseProgress(JSON.stringify({ day: "2026-01-01", introduced: 9, reviews: progress.reviews }))
      .reviews.abc.interval === DAY)
  t("an unknown card reads as new", G.stateFor(progress, "nope").phase === "new")
}

group("merging two surfaces' documents")
{
  const at = (t, extra) => Object.assign(
    { phase: "review", due: NOW, interval: DAY, ease: 2500, reps: 1, lapses: 0, step: 0, updated: t, firstDay: "" },
    extra || {})

  // The exact loss reproduced by hand: the overlay answers two cards, the bar
  // panel then saves a copy that predates both. Without merging, the panel's
  // write erased a card outright.
  const overlay = { reviews: { a: at(NOW + 10), b: at(NOW + 20) } }
  const stalePanel = { reviews: {} }
  const merged = G.mergeProgress(stalePanel, overlay)
  t("a stale document cannot erase the other surface's work",
    Object.keys(merged.reviews).sort().join(",") === "a,b")

  t("the newer entry wins", G.mergeProgress(
    { reviews: { a: at(NOW, { reps: 1 }) } },
    { reviews: { a: at(NOW + 5, { reps: 9 }) } }).reviews.a.reps === 9)
  t("and it wins from either side", G.mergeProgress(
    { reviews: { a: at(NOW + 5, { reps: 9 }) } },
    { reviews: { a: at(NOW, { reps: 1 }) } }).reviews.a.reps === 9)
  t("a card only one side knows is kept", G.mergeProgress(
    { reviews: { a: at(NOW) } }, { reviews: { b: at(NOW) } }).reviews.b !== undefined)
  t("a tie is deterministic, keeping mine", G.mergeProgress(
    { reviews: { a: at(NOW, { reps: 1 }) } },
    { reviews: { a: at(NOW, { reps: 9 }) } }).reviews.a.reps === 1)

  t("merging with nothing is a no-op",
    G.mergeProgress({ reviews: { a: at(NOW) } }, G.emptyProgress()).reviews.a !== undefined)
  t("merging into nothing adopts everything",
    G.mergeProgress(G.emptyProgress(), { reviews: { a: at(NOW) } }).reviews.a !== undefined)
  t("null operands are survivable", Object.keys(G.mergeProgress(null, null).reviews).length === 0)
  t("merged entries are normalized, not trusted",
    G.mergeProgress({ reviews: { a: { phase: "nonsense" } } }, null).reviews.a.phase === "new")
  t("merging does not mutate either operand", (() => {
    const mine = { reviews: { a: at(NOW, { reps: 1 }) } }
    G.mergeProgress(mine, { reviews: { a: at(NOW + 5, { reps: 9 }) } })
    return mine.reviews.a.reps === 1
  })())

  // Undo restores an older state, so it must be re-stamped or the merge would
  // hand back the very answer it just took back.
  t("an undo re-stamped as now survives a merge with the answer it undid", (() => {
    const answered = at(NOW + 10, { reps: 5 })
    const restored = at(NOW + 30, { reps: 4 })
    return G.mergeProgress({ reviews: { a: restored } }, { reviews: { a: answered } }).reviews.a.reps === 4
  })())
}

group("answers carry the stamps a merge needs")
{
  const answered = G.grade(G.newState(), "good", NOW)
  t("an answer is stamped with when it happened", answered.updated === NOW)
  t("a card leaving new is dated today", answered.firstDay === G.dayKey(NOW))

  const older = G.grade({ phase: "review", due: NOW, interval: DAY, ease: 2500, reps: 3, lapses: 0, step: 0, firstDay: "1999-01-01" }, "good", NOW)
  t("re-answering an old card keeps its original date", older.firstDay === "1999-01-01")
  t("but restamps when it changed", older.updated === NOW)
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
  const HOME = "/home/u"
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
// READ_SH and WRITE_SH are plain sh, so they are run as plain sh against real
// directories. What is being checked is that neither can be pointed at a file
// it was not meant to touch — including by a symlink planted at any component
// of the path, not merely at the file itself.

const sh = (script, home, rel, input) =>
  spawnSync("sh", ["-c", script, "omanki", home, rel],
            { input: input ?? "", encoding: "utf8" })

const REL = ".local/state/omarchy/omanki.json"
const CHAIN = [".local", ".local/state", ".local/state/omarchy"]

// A home with the chain already present, so a test can replace one link of it.
function makeHome() {
  const home = mkdtempSync(join(tmpdir(), "omanki-home-"))
  mkdirSync(join(home, ".local/state/omarchy"), { recursive: true })
  return home
}

function makeDecoy() {
  const dir = mkdtempSync(join(tmpdir(), "omanki-decoy-"))
  writeFileSync(join(dir, "omanki.json"), "untouched\n")
  return dir
}

group("writing creates its own chain, privately")
{
  const home = mkdtempSync(join(tmpdir(), "omanki-fresh-"))
  const doc = G.serializeProgress({ reviews: {} })
  const r = sh(G.WRITE_SH, home, REL, doc)

  t("a write into an empty home succeeds", r.status === 0)
  t("the document lands intact", readFileSync(join(home, REL), "utf8") === doc)
  t("the file is private", (statSync(join(home, REL)).mode & 0o777) === 0o600)
  for (const d of CHAIN)
    t(`${d} is created private`, (statSync(join(home, d)).mode & 0o777) === 0o700)
  t("no temp file is left behind",
    readdirSync(join(home, ".local/state/omarchy")).filter((f) => f.startsWith(".omanki.")).length === 0)
}

group("directories that already exist keep their modes")
{
  // ~/.local and ~/.config are shared with every other application. Tightening
  // them because a flashcard plugin happened to walk past would be overreach.
  const home = mkdtempSync(join(tmpdir(), "omanki-modes-"))
  mkdirSync(join(home, ".local"), { recursive: true, mode: 0o755 })
  chmodSync(join(home, ".local"), 0o755)

  const r = sh(G.WRITE_SH, home, REL, "{}\n")
  t("the write still succeeds", r.status === 0)
  t("an existing directory is left as it was",
    (statSync(join(home, ".local")).mode & 0o777) === 0o755)
  t("but one we create is still private",
    (statSync(join(home, ".local/state")).mode & 0o777) === 0o700)
}

group("a symlink planted at any component redirects nothing")
{
  // The whole point: guarding the final file is worthless if the walk to it
  // was already diverted. Each component gets its turn as the planted link.
  for (const component of CHAIN) {
    const home = makeHome()
    const decoy = makeDecoy()

    rmSync(join(home, component), { recursive: true, force: true })
    symlinkSync(decoy, join(home, component))

    const w = sh(G.WRITE_SH, home, REL, '{"reviews":{"pwned":{}}}\n')
    const r = sh(G.READ_SH, home, REL)

    t(`write is refused when ${component} is a symlink`, w.status === 65)
    t(`  the decoy file is untouched (${component})`,
      readFileSync(join(decoy, "omanki.json"), "utf8") === "untouched\n")
    t(`  no temp file is stranded beside the decoy (${component})`,
      readdirSync(decoy).filter((f) => f.startsWith(".omanki.")).length === 0)
    t(`  read is refused too (${component})`, r.status === 65 && r.stdout === "")
  }
}

group("a symlinked file, and a file where a directory belongs")
{
  const home = makeHome()
  const decoy = makeDecoy()

  symlinkSync(join(decoy, "omanki.json"), join(home, REL))
  t("a symlinked target file is refused on read", sh(G.READ_SH, home, REL).status === 65)

  const w = sh(G.WRITE_SH, home, REL, '{"reviews":{}}\n')
  t("but a write replaces the symlink instead of following it", w.status === 0)
  t("the decoy is untouched", readFileSync(join(decoy, "omanki.json"), "utf8") === "untouched\n")
  t("and the destination is now a real file",
    !lstatSync(join(home, REL)).isSymbolicLink())

  const home2 = mkdtempSync(join(tmpdir(), "omanki-file-"))
  mkdirSync(join(home2, ".local"), { recursive: true })
  writeFileSync(join(home2, ".local/state"), "i am not a directory\n")
  t("a regular file where a directory belongs is refused",
    sh(G.WRITE_SH, home2, REL, "{}\n").status === 66)
}

group("paths that walk out of home are refused before any work")
{
  const home = makeHome()
  for (const [label, rel] of [
    ["an absolute path", "/etc/passwd"],
    ["a parent traversal", ".local/../../etc/passwd"],
    ["a bare traversal", "../escape.json"],
    ["an empty path", ""],
  ]) t(`${label} is refused`, sh(G.WRITE_SH, home, rel, "{}\n").status === 64)

  t("containment is decided before the shell runs",
    G.relativeToHome("/etc/passwd", "/home/u") === "")
  t("a contained path is returned relative",
    G.relativeToHome("/home/u/.local/share/omanki/cards.json", "/home/u") === ".local/share/omanki/cards.json")
  t("home itself is not a file", G.relativeToHome("/home/u", "/home/u") === "")
  t("a sibling that merely shares a prefix is refused",
    G.relativeToHome("/home/user2/deck.json", "/home/u") === "")
  t("a traversal inside a contained path is refused",
    G.relativeToHome("/home/u/../etc/passwd", "/home/u") === "")
  t("a trailing slash on home is tolerated",
    G.relativeToHome("/home/u/a.json", "/home/u/") === "a.json")
  t("a relative path is refused", G.relativeToHome("a.json", "/home/u") === "")
}

group("reading, when there is simply nothing there")
{
  const home = mkdtempSync(join(tmpdir(), "omanki-empty-"))
  t("an unwalked chain reads as empty, not as an error",
    (() => { const r = sh(G.READ_SH, home, REL); return r.status === 0 && r.stdout === "" })())

  const home2 = makeHome()
  t("a missing file reads as empty",
    (() => { const r = sh(G.READ_SH, home2, REL); return r.status === 0 && r.stdout === "" })())

  writeFileSync(join(home2, REL), '{"reviews":{}}\n')
  t("a regular file is read", sh(G.READ_SH, home2, REL).stdout.trim() === '{"reviews":{}}')

  writeFileSync(join(home2, REL), "x".repeat(500_000))
  t("an oversized file is truncated, not swallowed whole",
    sh(G.READ_SH, home2, REL).stdout.length === 262_144)
}

group("the document itself is never interpolated")
{
  const home = makeHome()
  // Cards are user text and end up inside the document; it travels on stdin,
  // so quoting in a card cannot escape into the shell.
  const nasty = JSON.stringify({ reviews: { 'a"; rm -rf /; #': G.newState() } })
  const r = sh(G.WRITE_SH, home, REL, nasty)
  t("a document full of shell metacharacters is written verbatim",
    r.status === 0 && readFileSync(join(home, REL), "utf8") === nasty)
}

console.log(`\n${pass} passed, ${fail} failed`)
process.exit(fail ? 1 : 0)
