import QtQuick
import qs.Commons
import qs.Ui

// The four grades, each labelled with when it would bring the card back. Both
// the bar panel and the fullscreen overlay mount one of these, so there is a
// single implementation of the row and its pricing; the host owns how big it
// reads and when it is shown.
Row {
  id: root

  property var reviewer: null
  property color foreground: Color.foreground
  property color urgent: Color.urgent
  property string fontFamily: Style.font.family
  property real fontSize: Style.font.bodySmall
  property real captionSize: Style.font.caption

  spacing: Style.spacing.sm

  // Four equal columns and three gaps, so the row fills its host exactly
  // rather than leaving a ragged edge at whatever width it is given.
  readonly property real cellWidth: (width - spacing * 3) / 4

  Repeater {
    // Again is the one destructive answer, so it wears the urgent colour;
    // Good is the expected one and wears the accent. Hard and Easy stay
    // neutral rather than competing with them.
    model: [
      { grade: "again", label: "Again", key: "1", tone: "urgent" },
      { grade: "hard",  label: "Hard",  key: "2", tone: "muted"  },
      { grade: "good",  label: "Good",  key: "3", tone: "accent" },
      { grade: "easy",  label: "Easy",  key: "4", tone: "muted"  }
    ]

    Column {
      required property var modelData
      width: root.cellWidth
      spacing: Style.spacing.xxs

      Button {
        width: parent.width
        text: modelData.label
        bordered: true
        foreground: modelData.tone === "urgent" ? root.urgent
                  : modelData.tone === "accent" ? Color.accent
                  : root.foreground
        accent: modelData.tone === "urgent" ? root.urgent : Color.accent
        fontFamily: root.fontFamily
        fontSize: root.fontSize
        onClicked: if (root.reviewer) root.reviewer.answer(modelData.grade)
      }

      Text {
        width: parent.width
        horizontalAlignment: Text.AlignHCenter
        text: (root.reviewer ? root.reviewer.preview[modelData.grade] : "") + "  " + modelData.key
        color: root.foreground
        opacity: 0.4
        font.family: root.fontFamily
        font.pixelSize: root.captionSize
      }
    }
  }
}
