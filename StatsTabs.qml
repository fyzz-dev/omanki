import QtQuick
import qs.Commons

// The strip that names the panel's statistics tabs and says which one is
// showing.
//
// Its own file because it does not sit above the thing it switches: it rides on
// the end of the section header, where a second row of small-caps text directly
// under "STATISTICS" was two lines saying nearly the same thing and reading as
// one crowded block. The body it drives is PanelStats, further down the column.
//
// So this owns no state. The panel holds `tab`, this renders it and asks for a
// change, and PanelStats reads the same property — one owner, two readers,
// rather than a value bound in both directions between them.
Row {
  id: root

  property var tabs: []
  property int current: 0
  property color foreground: Color.foreground
  property color accent: Color.accent
  property string fontFamily: Style.font.family

  signal selected(int index)

  spacing: Style.spacing.md

  Repeater {
    model: root.tabs

    Item {
      id: chip
      required property var modelData
      required property int index
      readonly property bool active: root.current === chip.index

      width: label.implicitWidth
      height: label.implicitHeight + Style.spacing.xxs + Style.space(2)

      Text {
        id: label
        textFormat: Text.PlainText
        text: chip.modelData
        color: chip.active ? root.accent : root.foreground
        opacity: chip.active ? 1.0 : 0.4
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
      }

      // An underline rather than a filled chip. At this size a border round
      // every tab is more chrome than content, and this sits on a line that is
      // already carrying a section header — a row of boxes there would read as
      // the loudest thing in the panel.
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
        onClicked: root.selected(chip.index)
      }
    }
  }
}
