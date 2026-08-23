import QtQuick
import qs.Commons

Item {
  id: root
  property color color: Color.foreground
  property string fontFamily: Style.font.family
  property real iconSize: Style.font.icon
  property int badgeCount: 0
  property bool breathing: false

  implicitWidth: iconSize + (badgeCount > 0 ? Style.space(4) : 0)
  implicitHeight: iconSize

  Text {
    id: skull
    anchors.centerIn: parent
    text: "󰚌"
    color: root.color
    font.family: root.fontFamily
    font.pixelSize: root.iconSize
    opacity: root.breathing ? 0.55 : 1
    SequentialAnimation on opacity {
      running: root.breathing
      loops: Animation.Infinite
      NumberAnimation { to: 1; duration: 520; easing.type: Easing.InOutQuad }
      NumberAnimation { to: 0.45; duration: 520; easing.type: Easing.InOutQuad }
    }
  }

  Rectangle {
    visible: root.badgeCount > 0
    anchors.right: parent.right
    anchors.top: parent.top
    width: Math.max(Style.space(8), badge.implicitWidth + Style.space(3))
    height: width
    radius: width / 2
    color: root.color
    Text {
      id: badge
      anchors.centerIn: parent
      text: root.badgeCount > 9 ? "9+" : String(root.badgeCount)
      color: Color.background
      font.family: root.fontFamily
      font.pixelSize: Math.max(Style.space(6), root.iconSize * 0.42)
      font.bold: true
    }
  }
}
