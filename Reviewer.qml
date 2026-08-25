import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "Anki.js" as Anki

// The study session: owns the deck, the scheduling progress, and the queue,
// and knows nothing about what is hosting it. The panel mounts one of these
// and drives it with reveal()/answer(); everything else lives here.
Item {
  id: root

  // Absolute path to the deck the user authors, and the directory the
  // scheduling progress is written to.
  property string deckPath: ""
  property string stateDir: ""
  property int newPerDay: 20

  // Restrict the session to cards carrying any of these tags. Empty means the
  // whole deck.
  property var tags: []

  // False whenever the panel is closed, so a session neither ticks nor holds
  // a card revealed while nobody is looking at it.
  property bool active: false

  property color foreground: Color.foreground
  property color accent: Color.accent
  property color urgent: Color.urgent
  property string fontFamily: Style.font.family

  // How big the card reads and how much room it holds are the host's call, the
  // way Snake's hosts own `cell`. The bar panel is a popup and sizes to its
  // text; the fullscreen overlay is a study surface and wants a fixed, larger
  // face that does not jump as answers change length.
  property int minFaceHeight: 0
  property real questionFontSize: Style.font.heading
  property real answerFontSize: Style.font.subtitle

  // ----------------------------------------------------------------- state
  property var deck: []
  readonly property var cards: Anki.filterByTags(root.deck, root.tags)
  property var progress: Anki.emptyProgress()
  property var queue: []
  property string deckError: ""
  property bool loaded: false

  // Answered in this sitting, which is the only number that tells you whether
  // the session did anything — the due count moves for other reasons.
  property int answered: 0

  property bool revealed: false

  // Re-derived on every tick as well as on every answer, so a card that comes
  // due mid-session appears without the user doing anything.
  property var stats: Anki.counts(root.cards, root.progress, root.now, root.newPerDay)

  property int now: Math.floor(Date.now() / 1000)

  readonly property string currentId: root.queue.length ? root.queue[0] : ""
  readonly property var current: root.cardById(root.currentId)
  readonly property var currentState: Anki.stateFor(root.progress, root.currentId)

  // loading | error | empty | reviewing | waiting | done
  readonly property string phase: {
    if (!root.loaded) return "loading"
    if (root.deckError) return "error"
    if (root.current) return "reviewing"
    if (!root.cards.length) return "empty"
    if (root.stats.waiting > 0) return "waiting"
    return "done"
  }

  // Re-evaluated as `now` ticks, so an idle session counts down rather than
  // showing whatever the gap was when the last card was answered.
  readonly property string untilNext:
      root.stats.nextDue ? Anki.formatInterval(root.stats.nextDue - root.now) : ""

  readonly property var preview: root.current
      ? Anki.previewIntervals(root.currentState, root.now)
      : ({ again: "", hard: "", good: "", easy: "" })

  signal graded(string grade)

  Component.onCompleted: root.reload()

  // Coming back is the moment to pick up deck edits made while the panel was
  // closed, and to drop a card that was left face-up in the last session.
  onActiveChanged: {
    if (root.active) {
      root.revealed = false
      root.answered = 0
      root.reload()
    }
  }

  onDeckPathChanged: if (root.loaded) root.reload()
  onTagsChanged: if (root.loaded) root.rebuild()

  function cardById(id) {
    if (!id) return null
    for (var i = 0; i < root.cards.length; i++)
      if (root.cards[i].id === id) return root.cards[i]
    return null
  }

  // ------------------------------------------------------------- the session
  function refresh() {
    root.now = Math.floor(Date.now() / 1000)
    root.progress = Anki.rollDay(root.progress, root.now)
    root.stats = Anki.counts(root.cards, root.progress, root.now, root.newPerDay)
  }

  function rebuild() {
    root.refresh()
    root.queue = Anki.buildQueue(root.cards, root.progress, root.now, root.newPerDay)
    root.revealed = false
  }

  function reveal() {
    if (root.phase === "reviewing") root.revealed = true
  }

  // Space and Enter mean "show me the answer", then "I knew it" — the same two
  // presses Anki trains into your hands.
  function activate() {
    if (root.revealed) root.answer("good")
    else root.reveal()
  }

  function answer(g) {
    if (root.phase !== "reviewing" || !root.revealed) return

    var id = root.currentId
    var before = Anki.stateFor(root.progress, id)
    var after = Anki.grade(before, g, root.now)

    // Copied rather than mutated in place: `progress` is a var property, and
    // QML only re-evaluates the bindings that depend on it when the reference
    // itself changes.
    var reviews = {}
    for (var key in root.progress.reviews) reviews[key] = root.progress.reviews[key]
    reviews[id] = after

    var introduced = root.progress.introduced + (before.phase === "new" ? 1 : 0)
    root.progress = { day: root.progress.day, introduced: introduced, reviews: reviews }

    root.answered++
    root.save()
    root.rebuild()
    root.graded(g)
  }

  // --------------------------------------------------------------- loading
  function reload() {
    // Cleared first so a rebuild waits for both files again. A reader already
    // in flight still sets its own flag when it finishes, so nothing is lost
    // by not restarting it.
    root.deckRead = false
    root.progressRead = false
    if (!deckReader.running) deckReader.running = true
    if (!progressReader.running) progressReader.running = true
  }

  property bool deckRead: false
  property bool progressRead: false

  // The queue needs both files, and the two reads finish in whichever order
  // they finish, so building it waits for the pair.
  function readFinished() {
    if (!root.deckRead || !root.progressRead) return
    root.loaded = true
    root.rebuild()
  }

  Process {
    id: deckReader
    command: ["sh", "-c", Anki.READ_SH, "omanki-deck", root.deckPath]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        // An absent deck is the first-run state, not an error; a deck that
        // exists but does not parse is one the user needs told about.
        if (!text.trim()) {
          root.deck = []
          root.deckError = ""
        } else {
          var parsed = Anki.parseDeck(text)
          root.deck = parsed.cards
          root.deckError = parsed.error
        }
        root.deckRead = true
        root.readFinished()
      }
    }
  }

  Process {
    id: progressReader
    command: ["sh", "-c", Anki.READ_SH, "omanki-progress", root.stateDir + "/omanki.json"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.progress = Anki.parseProgress(text)
        root.progressRead = true
        root.readFinished()
      }
    }
  }

  // ---------------------------------------------------------------- saving
  // One writer at a time. Each document is complete, so a save that lands
  // mid-write waits and supersedes whatever was queued behind it.
  property string pendingSave: ""

  function save() {
    root.pendingSave = Anki.serializeProgress(root.progress)
    root.flushSave()
  }

  function flushSave() {
    if (!root.pendingSave || writer.running) return
    writer.document = root.pendingSave
    root.pendingSave = ""
    writer.running = true
  }

  Process {
    id: writer
    property string document: ""
    command: ["sh", "-c", Anki.WRITE_SH, "omanki-write", root.stateDir, "omanki.json"]
    stdinEnabled: true
    onStarted: {
      write(document)
      document = ""
      // Closing stdin is what tells `cat` the document is finished; without
      // it the write never completes and the next save never starts.
      stdinEnabled = false
    }
    onExited: root.flushSave()
  }

  // Two cadences from one timer.
  //
  // On screen it ticks every second, so a learning card due in a minute
  // arrives on its own without the user doing anything.
  //
  // Off screen it ticks slowly and re-reads both files, which is what keeps
  // the bar's count honest. Cards come due on a clock nobody is watching, and
  // the other surface writes progress this one has never seen — without this
  // the count would freeze at whatever it was when the surface last closed.
  Timer {
    interval: root.active ? 1000 : 60000
    running: root.loaded
    repeat: true
    onTriggered: {
      if (!root.active) {
        root.reload()
        return
      }

      var was = root.queue.length
      root.refresh()
      // Only rebuild when something actually became available — rebuilding
      // every second would reset the card under the user's hands.
      if (!was && root.stats.pending > 0) root.rebuild()
    }
  }

  // ---------------------------------------------------------------- render
  implicitHeight: content.implicitHeight

  Column {
    id: content
    width: parent.width
    spacing: Style.spacing.md

    // ------------------------------------------------------- the card face
    Rectangle {
      width: parent.width
      visible: root.phase === "reviewing"
      implicitHeight: Math.max(root.minFaceHeight, face.implicitHeight + Style.spacing.lg * 2)
      color: Util.alpha(root.foreground, 0.05)
      radius: Style.cornerRadius
      border.width: Math.max(1, Style.space(1))
      border.color: Util.alpha(root.foreground, 0.12)

      Column {
        id: face
        anchors.centerIn: parent
        width: parent.width - Style.spacing.lg * 2
        spacing: Style.spacing.md

        Text {
          width: parent.width
          horizontalAlignment: Text.AlignHCenter
          wrapMode: Text.Wrap
          text: root.current ? root.current.front : ""
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: root.questionFontSize
        }

        // The separator only appears with the answer, so the face of an
        // unrevealed card is the question and nothing else.
        Rectangle {
          width: parent.width
          height: Math.max(1, Style.space(1))
          visible: root.revealed
          color: Util.alpha(root.foreground, 0.15)
        }

        Text {
          width: parent.width
          visible: root.revealed
          horizontalAlignment: Text.AlignHCenter
          wrapMode: Text.Wrap
          text: root.current ? root.current.back : ""
          color: root.accent
          font.family: root.fontFamily
          font.pixelSize: root.answerFontSize
        }

        Text {
          width: parent.width
          visible: !root.revealed
          horizontalAlignment: Text.AlignHCenter
          text: "space to reveal"
          color: root.foreground
          opacity: 0.35
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }

    // --------------------------------------------------------- other states
    Text {
      width: parent.width
      visible: root.phase !== "reviewing"
      horizontalAlignment: Text.AlignHCenter
      wrapMode: Text.Wrap
      topPadding: Style.spacing.lg
      bottomPadding: Style.spacing.lg
      color: root.phase === "error" ? root.urgent : root.foreground
      opacity: root.phase === "error" ? 1.0 : 0.55
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      text: {
        if (root.phase === "loading") return "Loading deck…"
        if (root.phase === "error") return root.deckError + "\n" + root.deckPath

        // An empty session means one of two different things, and sending
        // someone to edit a deck that is actually full would be a wild goose
        // chase.
        if (root.phase === "empty") {
          return root.deck.length
              ? "No cards match #" + Anki.normalizeTags(root.tags).join(" #") + ".\n"
                + root.deck.length + " card" + (root.deck.length === 1 ? "" : "s") + " in the deck."
              : "No cards yet.\nAdd some to " + root.deckPath
        }

        if (root.phase === "waiting") return "Nothing due right now.\n"
            + root.stats.waiting + " card" + (root.stats.waiting === 1 ? "" : "s")
            + " still learning — next in " + root.untilNext + "."

        var done = root.answered > 0
            ? "Done for now — " + root.answered + " reviewed."
            : "Nothing due."
        return root.stats.nextDue ? done + "\nNext card in " + root.untilNext + "." : done
      }
    }
  }
}
