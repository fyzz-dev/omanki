import QtQuick
import qs.Commons
import qs.Ui
import "Anki.js" as Anki

// The statistics, sized for the bar panel.
//
// StatsView is the same numbers laid out for the overlay, which is a whole
// screen: it can afford a composition bar, a week of forecast, six figures in a
// grid and a paragraph of prose all at once. The panel is about 340 wide and
// tall enough for a card, so the same layout there would be a column of
// squeezed rows that says everything badly.
//
// So the panel gets tabs. One thing at a time, each sized to the space actually
// available, and the strip across the top says what else there is — which a
// scrolling column never does. Both views read the same `stats` object, so
// there is one calculation behind two presentations rather than two of either.
Item {
  id: root

  property var stats: null
  property color foreground: Color.foreground
  property color accent: Color.accent
  property color urgent: Color.urgent
  property string fontFamily: Style.font.family

  // Which tab is showing. Kept here rather than pushed in by the host: the
  // panel hides this component when it closes but never destroys it, so the
  // tab you were last reading is still the one you come back to.
  property int tab: 0

  signal restoreRequested()

  readonly property int total: root.stats ? root.stats.total : 0
  readonly property int seen: root.stats ? root.stats.seen : 0
  readonly property int leeches: root.stats ? (root.stats.leeches || 0) : 0
  readonly property int suspended: root.stats ? (root.stats.suspended || 0) : 0

  // The leech tab appears only once there is a leech, the way the overlay's
  // leech section does. A tab that is empty whenever you look at it is a tab
  // that teaches you not to look.
  readonly property var tabs: root.leeches > 0
      ? ["DECK", "DUE", "TODAY", "LEECHES"]
      : ["DECK", "DUE", "TODAY"]

  readonly property int count: root.tabs.length

  function select(i) {
    root.tab = Math.max(0, Math.min(root.count - 1, i))
  }

  // Wraps, so the arrow keys walk the strip in a circle rather than stopping
  // at the ends and leaving the reader to work out which end they are on.
  function step(delta) {
    root.tab = ((root.tab + delta) % root.count + root.count) % root.count
  }

  // A tab that disappears - the leech one, once the last leech is restored -
  // must not leave the view pointing past the end of the strip.
  onCountChanged: if (root.tab >= root.count) root.tab = root.count - 1

  implicitHeight: strip.height + Style.spacing.md + body.height

  // ------------------------------------------------------------- the strip
  Row {
    id: strip
    width: parent.width
    spacing: Style.spacing.md

    Repeater {
      model: root.tabs

      Item {
        id: chip
        required property var modelData
        required property int index
        readonly property bool active: root.tab === chip.index

        width: label.implicitWidth
        height: label.implicitHeight + Style.spacing.xs + Style.space(2)

        Text {
          id: label
          textFormat: Text.PlainText
          text: chip.modelData
          color: chip.active ? root.accent : root.foreground
          opacity: chip.active ? 1.0 : 0.45
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
        }

        // An underline rather than a filled chip: at this size a border round
        // every tab is more chrome than content, and the panel's other
        // section headers are already plain small-caps text.
        Rectangle {
          anchors.bottom: parent.bottom
          width: parent.width
          height: Style.space(2)
          radius: Style.cornerRadius > 0 ? height : 0
          color: root.accent
          visible: chip.active
        }

        MouseArea {
          anchors.fill: parent
          cursorShape: Qt.PointingHandCursor
          onClicked: root.select(chip.index)
        }
      }
    }
  }

  // --------------------------------------------------------------- the body
  //
  // One height for every tab, taken from the tallest, so that moving along the
  // strip does not resize the panel under the pointer. A panel that changes
  // height as you read it is worse than one that carries a little air.
  Item {
    id: body
    width: parent.width
    // Taken from the tallest tab rather than a number picked by eye, so the
    // panel keeps one height across the strip without the figure needing to be
    // rechecked every time a tab gains a line.
    height: Math.max(deckTab.implicitHeight, dueTab.implicitHeight,
                     todayTab.implicitHeight, leechTab.implicitHeight)
    anchors.top: strip.bottom
    anchors.topMargin: Style.spacing.md

    // ------------------------------------------------------------ deck
    Column {
      id: deckTab
      width: parent.width
      spacing: Style.spacing.sm
      visible: root.tab === 0

      Row {
        width: parent.width
        spacing: Style.spacing.sm

        Text {
          textFormat: Text.PlainText
          anchors.baseline: pct.baseline
          text: root.total + (root.total === 1 ? " card" : " cards")
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.subtitle
        }

        Text {
          id: pct
          textFormat: Text.PlainText
          text: root.total ? Anki.percent(root.seen / root.total) + " seen" : ""
          color: root.foreground
          opacity: 0.5
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }

      // The shape of the deck reads faster than its arithmetic, which is why
      // this is a bar and the numbers under it are a caption.
      Row {
        width: parent.width
        height: Style.space(8)
        spacing: Math.max(1, Style.space(1))

        Repeater {
          model: [
            { key: "mature",   tone: root.accent,     alpha: 1.00 },
            { key: "young",    tone: root.accent,     alpha: 0.55 },
            { key: "learning", tone: root.urgent,     alpha: 0.85 },
            { key: "fresh",    tone: root.foreground, alpha: 0.18 }
          ]

          Rectangle {
            id: seg
            required property var modelData
            readonly property int n: root.stats ? (root.stats[seg.modelData.key] || 0) : 0
            height: parent.height
            width: root.total > 0
                ? Math.max(seg.n > 0 ? Style.space(2) : 0,
                           (parent.width - Style.space(3)) * seg.n / root.total)
                : 0
            visible: seg.n > 0
            radius: Style.cornerRadius > 0 ? height / 2 : 0
            color: Util.alpha(seg.modelData.tone, seg.modelData.alpha)
          }
        }
      }

      // Two rows of two rather than one row of four: four labels and four
      // numbers do not fit across a panel without shrinking past reading size.
      Grid {
        width: parent.width
        columns: 2
        columnSpacing: Style.spacing.md
        rowSpacing: Style.spacing.xs

        Repeater {
          model: [
            { label: "mature",   key: "mature" },
            { label: "young",    key: "young" },
            { label: "learning", key: "learning" },
            { label: "unseen",   key: "fresh" }
          ]

          Text {
            required property var modelData
            textFormat: Text.PlainText
            width: (parent.width - Style.spacing.md) / 2
            text: (root.stats ? (root.stats[modelData.key] || 0) : 0) + " " + modelData.label
            color: root.foreground
            opacity: 0.55
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }
    }

    // ------------------------------------------------------------- due
    Column {
      id: dueTab
      width: parent.width
      spacing: Style.spacing.sm
      visible: root.tab === 1

      Text {
        textFormat: Text.PlainText
        text: {
          if (!root.stats || !root.stats.forecast) return ""
          var n = 0
          for (var i = 0; i < root.stats.forecast.length; i++) n += root.stats.forecast[i]
          return n + (n === 1 ? " card" : " cards") + " over the next week"
        }
        color: root.foreground
        opacity: 0.55
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }

      Row {
        width: parent.width
        height: Style.space(62)
        spacing: Style.spacing.xs

        Repeater {
          model: 7

          Column {
            id: day
            required property int index
            readonly property int n:
                (root.stats && root.stats.forecast) ? (root.stats.forecast[day.index] || 0) : 0

            // Scaled against the busiest day rather than an absolute count, so
            // a quiet week still has a shape instead of seven stubs.
            readonly property int peak: {
              if (!root.stats || !root.stats.forecast) return 1
              var max = 1
              for (var i = 0; i < root.stats.forecast.length; i++)
                max = Math.max(max, root.stats.forecast[i])
              return max
            }

            width: (parent.width - Style.spacing.xs * 6) / 7
            spacing: Style.space(2)

            Text {
              textFormat: Text.PlainText
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              text: day.n > 0 ? String(day.n) : ""
              color: root.foreground
              opacity: 0.55
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            Item {
              id: plot
              width: parent.width
              height: Style.space(32)

              Rectangle {
                anchors.bottom: parent.bottom
                width: parent.width
                height: day.n > 0
                    ? Math.max(Style.space(3), plot.height * day.n / day.peak)
                    : Math.max(1, Style.space(1))
                radius: Style.cornerRadius > 0 ? Style.space(2) : 0
                color: day.n > 0
                    ? Util.alpha(root.accent, day.index === 0 ? 1.0 : 0.45)
                    : Util.alpha(root.foreground, 0.12)
              }
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              text: day.index === 0 ? "now" : "+" + day.index
              color: root.foreground
              opacity: 0.35
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }
        }
      }
    }

    // ----------------------------------------------------------- today
    Column {
      id: todayTab
      width: parent.width
      spacing: Style.spacing.md
      visible: root.tab === 2

      Row {
        width: parent.width

        Repeater {
          model: [
            { label: "ANSWERED", key: "answeredToday" },
            { label: "NEW",      key: "introducedToday" },
            { label: "REVIEWS",  key: "reviewsToday" }
          ]

          Column {
            required property var modelData
            width: parent.width / 3
            spacing: Style.space(2)

            Text {
              textFormat: Text.PlainText
              text: root.stats ? String(root.stats[modelData.key] || 0) : "0"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
            }

            Text {
              textFormat: Text.PlainText
              text: modelData.label
              color: root.foreground
              opacity: 0.45
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }
        }
      }

      // Ease and retention are deck-wide rather than today's, but they are the
      // two numbers that answer "is this working", which is the question the
      // rest of this tab is about.
      Text {
        textFormat: Text.PlainText
        width: parent.width
        wrapMode: Text.Wrap
        text: root.stats
            ? "ease " + root.stats.ease.toFixed(2)
              + "  ·  " + Anki.percent(root.stats.retention) + " never relearned"
              + "  ·  " + root.stats.lapsed + " lapsed"
            : ""
        color: root.foreground
        opacity: 0.45
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }

    // --------------------------------------------------------- leeches
    Column {
      id: leechTab
      width: parent.width
      spacing: Style.spacing.sm
      visible: root.tab === 3 && root.leeches > 0

      Text {
        textFormat: Text.PlainText
        width: parent.width
        wrapMode: Text.Wrap
        text: {
          var n = root.leeches
          var head = n + (n === 1 ? " card has" : " cards have") + " lapsed enough to count as a leech"
          if (root.suspended > 0)
            return head + ", and " + root.suspended + " of them "
                + (root.suspended === 1 ? "is" : "are") + " suspended."
          return head + ". None are suspended."
        }
        color: root.foreground
        opacity: 0.6
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }

      // The panel had no way back before this view existed - it said "restore
      // in the overlay" and left you to go there. Now that the count is here,
      // the way back belongs here too.
      Button {
        visible: root.suspended > 0
        text: root.suspended === 1 ? "Restore 1 card" : "Restore " + root.suspended + " cards"
        bordered: true
        foreground: root.foreground
        accent: root.accent
        fontFamily: root.fontFamily
        fontSize: Style.font.bodySmall
        onClicked: root.restoreRequested()
      }
    }
  }
}
