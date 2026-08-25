# omanki

Spaced-repetition flashcards in the Omarchy bar, scheduled the way Anki
schedules them.

There are two surfaces onto the same deck:

- **The bar panel.** Click the glyph to clear a few cards in passing.
- **The fullscreen overlay.** `Super + Ctrl + J` for actually sitting down to a
  deck — a bigger card face, on a surface with nothing else on it.

Both run the same session and write the same progress, so a card answered in
one is answered in the other. Either way the loop is the same: question, space
to reveal, then one of four grades, each labelled with when the card would
come back.

```
󰘸 7        →     omanki                    7
                 3 due · 4 new

                 NEW

                 ┌──────────────────────┐
                 │  Toggle the scratchpad │
                 │  ──────────────────── │
                 │      Super + S         │
                 └──────────────────────┘

                 Again   Hard   Good   Easy
                  1m      10m    10m    4d
                  1        2      3      4
```

## Keys

| Key | Does |
|-----|------|
| `space` / `enter` | Reveal the answer, then grade it Good |
| `1` `2` `3` `4` | Again / Hard / Good / Easy |
| `r` | Reload the deck from disk |
| `esc` | Close |

Same keys on both surfaces. `Super + Ctrl + J` toggles the overlay; the bar
glyph toggles the panel.

## Your deck

Cards live in `~/.local/share/omanki/cards.json`, which is yours to edit:

```json
{
  "cards": [
    { "front": "Toggle the scratchpad", "back": "Super + S", "tags": ["omarchy"] }
  ]
}
```

A bare `[ ... ]` array works too. Entries missing a front or a back are
skipped rather than shown blank, and the panel says so if the file does not
parse. Press `r` in the panel, or just close and reopen it, to pick up edits.

A card is identified by a hash of its **front**, not by its position in the
file, so you can reorder the deck or fix a typo on the back without losing a
card's history. Changing the front is deliberately a new card — the question
changed, and the old schedule was earned answering a different one. Set an
explicit `"id"` on a card if you want to edit a front and keep its progress.

Scheduling progress is kept separately, in
`~/.local/state/omarchy/omanki.json`, so nothing the plugin writes can clobber
the deck you are writing by hand. Deleting that file resets every card to new
and leaves your deck alone.

## Settings

Set these on the plugin's entry in `~/.config/omarchy/shell.json`; it
hot-reloads on save.

| Setting | Default | Does |
|---------|---------|------|
| `deck` | `~/.local/share/omanki/cards.json` | Path to the deck file. `~` is expanded. |
| `newPerDay` | `20` | How many unseen cards to introduce per study day. `0` reviews only. |
| `showCount` | `true` | Show the waiting count next to the bar glyph. |

```json
{ "id": "yamz8.omanki", "newPerDay": 10, "deck": "~/notes/spanish.json" }
```

## How the scheduling works

SM-2, in the shape Anki uses it.

A **new** card is shown after 1 minute, then after 10, then graduates to a
1-day interval. *Easy* skips straight to 4 days. Nothing in this phase touches
ease — a card you have not learned yet has no history to judge it by.

A **review** card's interval is multiplied by its ease factor (2.5 to start).
*Hard* multiplies by 1.2 and costs 150 ease, *Good* multiplies by the ease
itself, *Easy* adds a 1.3 bonus and earns 150 ease. Ease is held between 1.3
and 3.0. A passing grade always pushes the card further out than it was, even
when the multiplier rounds to nothing.

*Again* on a review card is a **lapse**: it costs 200 ease, halves the
interval, and sends the card through a 10-minute relearning step. Coming out
of relearning restores that halved interval rather than starting over at a
day, so one slip does not erase months of spacing.

The study day rolls over at **4am** local time, not midnight, so a card
answered at 1am counts toward the day you are still awake in. That is what the
`newPerDay` allowance is measured against.

## Tests

The scheduler is deliberately free of QML types, so it runs under plain node:

```bash
node tests/scheduler.test.mjs
```

That covers the learning steps, interval growth, lapses and recovery, the
clamps, deck parsing, queue order, the 4am rollover, and the hardening on both
file-I/O snippets.

## Layout

| File | What it is |
|------|------------|
| `Anki.js` | Scheduling, deck parsing, settings, file I/O snippets. No QML types. |
| `Reviewer.qml` | The session: deck, progress, queue, persistence, card face. |
| `GradeButtons.qml` | The four priced grade buttons, shared by both surfaces. |
| `Panel.qml` | The bar widget and the panel chrome around the session. |
| `Omanki.qml` | The fullscreen overlay chrome around the same session. |

`Reviewer` and `GradeButtons` know nothing about what is hosting them — the
host owns sizing, the same way Snake's hosts own `cell` — so the rules and the
review loop exist once rather than once per surface.

While a surface is on screen its session ticks every second, so a card due in
a minute arrives on its own. While it is closed it ticks once a minute and
re-reads both files, which is what keeps the bar's count honest when cards
come due unattended or the other surface has been answering them.

## Installing it in the bar

```bash
omarchy bar put yamz8.omanki --section right
```

Or add `{ "id": "yamz8.omanki" }` to a section of `bar.layout` in
`~/.config/omarchy/shell.json` by hand.

The overlay is summoned by keybind. In `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + CTRL + J", "omanki", "omarchy-shell shell toggle yamz8.omanki")
```

Pick that key with care. `SUPER + CTRL + M` looks free and is not — it sits one
modifier key away from Omarchy's stock `SUPER + SHIFT + M` "Music" binding, and
missing Ctrl for Shift launches `omarchy-launch-spotify`, which offers to
install Spotify if it is absent. Check a candidate against the live table
rather than the config, since the two can disagree:

```bash
omarchy menu keybindings --print | grep -i "SUPER CTRL"
```

A note if you are hacking on this: the Omarchy shell hot-reloads plugin code,
but a shell process that started *before* the plugin directory existed cannot
load a newly added overlay entry point — Qt caches its view of the filesystem
and reports it as a spurious "File name case mismatch". `omarchy restart shell`
once after adding a new entry point, and hot-reload works normally from then on.
