import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import "Anki.js" as Anki

// Bar widget: a card glyph with the number of cards waiting, opening the
// review session in a standard popup panel. Built on the same Ui.Panel base as
// Network and Tailscale so it inherits their open/close lifecycle, popout
// coordination, and IPC.
Panel {
  id: root
  moduleName: "yamz8.omanki"
  ipcTarget: "yamz8.omanki"

  // Bar widgets are handed their inline shell.json entry, so `setting()` from
  // the Panel base is all the config plumbing this surface needs.
  readonly property string deckPath: Anki.resolveDeck(root.setting("deck", ""), Quickshell.env("HOME"))
  readonly property int newPerDay: Anki.sanePerDay(root.setting("newPerDay", 20))
  readonly property var tags: Anki.normalizeTags(root.setting("tags", []))
  readonly property int reviewsPerDay: Anki.sanePerDay(root.setting("reviewsPerDay", 0), 0)
  readonly property int leechThreshold: Anki.sanePerDay(root.setting("leechThreshold", Anki.LEECH_THRESHOLD), Anki.LEECH_THRESHOLD)
  readonly property bool leechSuspend: root.setting("leechSuspend", true) !== false
  readonly property int lapsePercent: Anki.sanePerDay(root.setting("lapsePercent", Anki.LAPSE_PERCENT), Anki.LAPSE_PERCENT)
  // The count is the point of the widget, but a bar that has to stay narrow
  // can turn it off and keep the glyph.
  readonly property bool showCount: root.setting("showCount", true) !== false

  // The bar sizes a widget from its implicit size, and Ui.Panel is a bare Item
  // with none — without this the widget occupies 0x0 and draws nothing.
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property int panelContentWidth: Style.space(340)
  readonly property int pending: reviewer.stats ? reviewer.stats.pending : 0

  // WidgetButton rather than BarIconButton: the count makes this a
  // variable-width label, and BarIconButton is a fixed single-glyph slot that
  // would squeeze the number into the icon's box.
  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.showCount && root.pending > 0 ? "󰘸 " + root.pending : "󰘸"
    fontSize: Style.bar.iconFont
    // Cards waiting is the whole signal; with none, the widget should recede
    // rather than sit at full strength all day.
    dimmed: root.pending === 0
    tooltipText: root.pending > 0
        ? root.pending + " card" + (root.pending === 1 ? "" : "s") + " to review"
        : "omanki — nothing due"
    onPressed: function(buttonCode) { root.toggle() }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(root.panelContentWidth)
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(620))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      // Space and Enter both arrive as activate, which is exactly the
      // reveal-then-grade rhythm Anki uses.
      onActivateRequested: reviewer.activate()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        var k = t.toLowerCase()
        if (k === "1") reviewer.answer("again")
        else if (k === "2") reviewer.answer("hard")
        else if (k === "3") reviewer.answer("good")
        else if (k === "4") reviewer.answer("easy")
        else if (k === "u") reviewer.undo()
        else if (k === "r") reviewer.reload()
      }

      Column {
        id: column
        width: parent.width
        spacing: Style.space(12)

        PanelHero {
          width: parent.width
          title: "omanki"
          meta: {
            if (reviewer.phase === "loading") return "Loading"
            if (reviewer.phase === "error") return "Deck error"
            if (reviewer.phase === "empty") return "Empty deck"
            var s = reviewer.stats
            if (!s.pending) return s.total + " card" + (s.total === 1 ? "" : "s") + "  ·  all caught up"
            return s.due + " due  ·  " + s.fresh + " new"
          }
          foreground: root.foreground
          fontFamily: root.fontFamily

          iconComponent: Component {
            Text {
              textFormat: Text.PlainText
              text: "󰘸"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.display
            }
          }

          // How many are left, on the trailing edge — the slot the native
          // panels use for at-a-glance state.
          trailingControl: Component {
            Row {
              spacing: Style.spacing.md

              Text {
                textFormat: Text.PlainText
                anchors.verticalCenter: parent.verticalCenter
                visible: reviewer.answered > 0
                text: "Done " + reviewer.answered
                color: root.foreground
                opacity: 0.5
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }

              Text {
                textFormat: Text.PlainText
                anchors.verticalCenter: parent.verticalCenter
                text: String(root.pending)
                color: root.pending > 0 ? Color.accent : root.foreground
                opacity: root.pending > 0 ? 1.0 : 0.4
                font.family: root.fontFamily
                font.pixelSize: Style.font.title
              }
            }
          }
        }

        PanelSeparator {
          width: parent.width
          foreground: root.foreground
        }

        PanelSectionHeader {
          textFormat: Text.PlainText
          width: parent.width
          text: Anki.sectionLabel(reviewer.phase, reviewer.currentState, root.tags)
          foreground: root.foreground
          fontFamily: root.fontFamily
        }

        Reviewer {
          id: reviewer
          width: parent.width
          deckPath: root.deckPath
          stateDir: Quickshell.env("HOME") + "/.local/state/omarchy"
          newPerDay: root.newPerDay
          reviewsPerDay: root.reviewsPerDay
          leechThreshold: root.leechThreshold
          leechSuspend: root.leechSuspend
          lapsePercent: root.lapsePercent
          tags: root.tags
          active: root.opened
          foreground: root.foreground
          accent: Color.accent
          urgent: root.urgent
          fontFamily: root.fontFamily
        }

        // Shown only with the answer: grading a card you have not turned over
        // is guessing, not recall.
        GradeButtons {
          width: parent.width
          visible: reviewer.phase === "reviewing" && reviewer.revealed
          reviewer: reviewer
          foreground: root.foreground
          urgent: root.urgent
          fontFamily: root.fontFamily
        }

        Text {
          textFormat: Text.PlainText
          width: parent.width
          horizontalAlignment: Text.AlignHCenter
          // The bar panel has no statistics view to restore from, so it says
          // where the restoring lives rather than offering a key it does not
          // have. Saying nothing would leave a card gone with no account of it.
          text: reviewer.leechNotice
              ? reviewer.leechNotice + "  ·  restore in the overlay"
              : (reviewer.revealed ? "1-4 grade  ·  space good" : "space reveal")
                + (reviewer.canUndo ? "  ·  u undo" : "")
                + "  ·  r reload  ·  esc close"
          color: root.foreground
          opacity: 0.4
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }
  }
}
