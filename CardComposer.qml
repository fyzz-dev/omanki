import QtQuick
import qs.Commons
import qs.Ui

// Write a card into the deck without leaving the review surface. Three fields
// and a save: the deck file stays the source of truth and anything more
// elaborate belongs in a text editor, which the user already has.
Column {
  id: root

  property var reviewer: null
  property color foreground: Color.foreground
  property color accent: Color.accent
  property color urgent: Color.urgent
  property string fontFamily: Style.font.family

  signal dismissed()

  spacing: Style.spacing.md

  // Escape has to be caught here, not by the overlay. The overlay's key
  // catcher is a *sibling* of the content, so it only sees keys while it holds
  // focus itself — and the moment a field takes focus for typing, nothing
  // reaches it. This Column is a real ancestor of the fields, so an Escape
  // they do not handle arrives here.
  Keys.onEscapePressed: function(event) {
    root.dismissed()
    event.accepted = true
  }

  function reset() {
    frontField.text = ""
    backField.text = ""
    tagsField.text = ""
    if (root.reviewer) root.reviewer.addError = ""
  }

  function focusFirst() {
    frontField.forceActiveFocus()
  }

  function commit() {
    if (!root.reviewer) return
    if (!frontField.text.trim() || !backField.text.trim()) {
      // Say which half is missing rather than refusing silently.
      if (!frontField.text.trim()) frontField.forceActiveFocus()
      else backField.forceActiveFocus()
      return
    }

    var tags = tagsField.text.split(",")
    root.reviewer.addCard(frontField.text, backField.text, tags)
  }

  // The reviewer clears its error when an add is accepted, so a successful
  // write is the signal to empty the form and stay ready for the next card.
  Connections {
    target: root.reviewer
    function onCardAdded() {
      root.reset()
      root.focusFirst()
    }
  }

  TextField {
    id: frontField
    width: parent.width
    placeholderText: "Front — the question"
    foreground: root.foreground
    accent: root.accent
    font.family: root.fontFamily
    font.pixelSize: Style.font.body
    onAccepted: backField.forceActiveFocus()
  }

  TextField {
    id: backField
    width: parent.width
    placeholderText: "Back — the answer"
    foreground: root.foreground
    accent: root.accent
    font.family: root.fontFamily
    font.pixelSize: Style.font.body
    onAccepted: tagsField.forceActiveFocus()
  }

  TextField {
    id: tagsField
    width: parent.width
    placeholderText: "Tags, comma separated (optional)"
    foreground: root.foreground
    accent: root.accent
    font.family: root.fontFamily
    font.pixelSize: Style.font.body
    onAccepted: root.commit()
  }

  Text {
    width: parent.width
    wrapMode: Text.Wrap
    visible: !!(root.reviewer && root.reviewer.addError)
    text: root.reviewer ? root.reviewer.addError : ""
    color: root.urgent
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
  }

  Row {
    width: parent.width
    spacing: Style.spacing.sm

    Button {
      text: root.reviewer && root.reviewer.adding ? "Saving…" : "Add card"
      enabled: !(root.reviewer && root.reviewer.adding)
      bordered: true
      foreground: root.accent
      accent: root.accent
      fontFamily: root.fontFamily
      fontSize: Style.font.body
      onClicked: root.commit()
    }

    Button {
      text: "Done"
      bordered: true
      foreground: root.foreground
      accent: root.accent
      fontFamily: root.fontFamily
      fontSize: Style.font.body
      onClicked: root.dismissed()
    }
  }

  Text {
    width: parent.width
    horizontalAlignment: Text.AlignHCenter
    text: "enter moves on  ·  enter on tags saves  ·  esc back to review"
    color: root.foreground
    opacity: 0.4
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }
}
