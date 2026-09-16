import QtQuick
import qs.Commons
import qs.Ui
import "Anki.js" as Anki

// What the deck looks like from above: how far through it you are, what is
// coming, and whether the scheduling is working. Everything shown is derived
// from the cards themselves — the plugin keeps no review log, so nothing here
// depends on history it does not have.
Column {
  id: root

  property var stats: null
  property color foreground: Color.foreground
  property color accent: Color.accent
  property color urgent: Color.urgent
  property string fontFamily: Style.font.family

  spacing: Style.spacing.lg

  readonly property int seen: root.stats ? root.stats.seen : 0
  readonly property int total: root.stats ? root.stats.total : 0
  readonly property int leeches: root.stats ? (root.stats.leeches || 0) : 0
  readonly property int suspended: root.stats ? (root.stats.suspended || 0) : 0

  // ------------------------------------------------------------- composition
  // One bar rather than four numbers: the shape of a deck — how much is still
  // unseen, how much is still shaky — reads faster than its arithmetic.
  Column {
    width: parent.width
    spacing: Style.spacing.sm

    Row {
      width: parent.width
      spacing: Style.spacing.md

      Text {
        textFormat: Text.PlainText
        text: root.total + " cards"
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.subtitle
      }

      Text {
        textFormat: Text.PlainText
        anchors.verticalCenter: parent.verticalCenter
        text: root.total ? Anki.percent(root.seen / root.total) + " seen" : ""
        color: root.foreground
        opacity: 0.5
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
      }
    }

    Row {
      width: parent.width
      height: Style.space(10)
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
          readonly property int count: root.stats ? (root.stats[seg.modelData.key] || 0) : 0
          height: parent.height
          // Widths are shares of the whole deck, less the hairline gaps.
          width: root.total > 0
              ? Math.max(seg.count > 0 ? Style.space(2) : 0,
                         (parent.width - Style.space(3)) * seg.count / root.total)
              : 0
          visible: seg.count > 0
          radius: Style.cornerRadius > 0 ? height / 2 : 0
          color: Util.alpha(seg.modelData.tone, seg.modelData.alpha)
        }
      }
    }

    Row {
      width: parent.width
      spacing: Style.spacing.md

      Repeater {
        model: [
          { label: "mature",   key: "mature" },
          { label: "young",    key: "young" },
          { label: "learning", key: "learning" },
          { label: "unseen",   key: "fresh" }
        ]

        Text {
          textFormat: Text.PlainText
          required property var modelData
          text: (root.stats ? (root.stats[modelData.key] || 0) : 0) + " " + modelData.label
          color: root.foreground
          opacity: 0.5
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }
  }

  PanelSeparator {
    width: parent.width
    foreground: root.foreground
  }

  // ---------------------------------------------------------------- forecast
  Column {
    width: parent.width
    spacing: Style.spacing.sm

    PanelSectionHeader {
      textFormat: Text.PlainText
      width: parent.width
      text: "DUE OVER THE NEXT WEEK"
      foreground: root.foreground
      fontFamily: root.fontFamily
    }

    Row {
      width: parent.width
      height: Style.space(56)
      spacing: Style.spacing.sm

      Repeater {
        model: 7

        Column {
          id: day
          required property int index

          readonly property int count:
              (root.stats && root.stats.forecast) ? (root.stats.forecast[day.index] || 0) : 0

          // Bars are scaled against the busiest day rather than an absolute
          // count, so a quiet week still has shape instead of seven stubs.
          readonly property int peak: {
            if (!root.stats || !root.stats.forecast) return 1
            var max = 1
            for (var i = 0; i < root.stats.forecast.length; i++)
              max = Math.max(max, root.stats.forecast[i])
            return max
          }

          width: (parent.width - Style.spacing.sm * 6) / 7
          spacing: Style.spacing.xxs

          Item {
            id: plot
            width: parent.width
            height: Style.space(38)

            Rectangle {
              anchors.bottom: parent.bottom
              width: parent.width
              height: day.count > 0
                  ? Math.max(Style.space(3), plot.height * day.count / day.peak)
                  : Math.max(1, Style.space(1))
              radius: Style.cornerRadius > 0 ? Style.space(2) : 0
              color: day.count > 0
                  ? Util.alpha(root.accent, day.index === 0 ? 1.0 : 0.45)
                  : Util.alpha(root.foreground, 0.12)
            }
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: day.count > 0 ? String(day.count) : ""
            color: root.foreground
            opacity: 0.55
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
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

  PanelSeparator {
    width: parent.width
    foreground: root.foreground
  }

  // ------------------------------------------------------------------ figures
  Grid {
    width: parent.width
    columns: 3
    columnSpacing: Style.spacing.lg
    rowSpacing: Style.spacing.md

    Repeater {
      model: [
        { label: "ANSWERED TODAY", value: root.stats ? String(root.stats.answeredToday) : "0" },
        { label: "NEW TODAY",      value: root.stats ? String(root.stats.introducedToday) : "0" },
        { label: "REVIEWS TODAY",  value: root.stats ? String(root.stats.reviewsToday) : "0" },
        { label: "AVERAGE EASE",   value: root.stats ? root.stats.ease.toFixed(2) : "0" },
        { label: "LAPSED CARDS",   value: root.stats ? String(root.stats.lapsed) : "0" },
        { label: "RETENTION",      value: root.stats ? Anki.percent(root.stats.retention) : "0%" }
      ]

      Column {
        required property var modelData
        spacing: Style.spacing.xxs

        Text {
          textFormat: Text.PlainText
          text: modelData.label
          color: root.foreground
          opacity: 0.45
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        Text {
          textFormat: Text.PlainText
          text: modelData.value
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.title
        }
      }
    }
  }

  // --------------------------------------------------------------- leeches
  // Only when there are any. A deck with no leeches is the ordinary case and
  // should not carry a row of zeroes explaining a thing that has not happened.
  //
  // This is also the only place a suspended card can be found again: there is
  // no card browser to go looking in, so the count and the way back have to be
  // in the same sentence, or suspending would be a one-way door.
  Column {
    width: parent.width
    spacing: Style.spacing.sm
    visible: root.leeches > 0

    PanelSeparator {
      width: parent.width
      foreground: root.foreground
    }

    PanelSectionHeader {
      textFormat: Text.PlainText
      width: parent.width
      text: "LEECHES"
      foreground: root.foreground
      fontFamily: root.fontFamily
    }

    Text {
      textFormat: Text.PlainText
      width: parent.width
      wrapMode: Text.Wrap
      text: {
        var n = root.leeches
        var s = root.suspended
        var head = n === 1
            ? "1 card has lapsed enough to count as a leech"
            : n + " cards have lapsed enough to count as a leech"
        if (s === 0) return head + ". None are suspended."
        if (s === n) return head + (n === 1 ? ", and it is suspended." : ", and all of them are suspended.")
        return head + ", and " + s + " of them " + (s === 1 ? "is" : "are") + " suspended."
      }
      color: root.foreground
      opacity: 0.55
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  // Retention has no review log behind it, and saying so is cheaper than
  // letting someone read it as Anki's number.
  Text {
    textFormat: Text.PlainText
    width: parent.width
    wrapMode: Text.Wrap
    text: "Retention is a lifetime figure per card — answers that never had to be relearned — not a rolling window."
    color: root.foreground
    opacity: 0.35
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }
}
