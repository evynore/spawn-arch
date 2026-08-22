import QtQuick
import QtQuick.Layouts
import Quickshell
import "."

PopupWindow {
    id: root
    property var panel
    anchor.window: panel
    anchor.rect.x: panel ? panel.width - width - Theme.spaceSm : 0
    anchor.rect.y: panel ? panel.height + Theme.spaceSm : 0
    width: 420
    height: 320
    visible: false
    grabFocus: true
    color: "transparent"

    Rectangle {
        anchors.fill: parent
        radius: Theme.radiusLg
        color: Theme.surface
        border.color: Theme.focus
        border.width: 1

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: Theme.spaceLg
            spacing: Theme.spaceMd

            RowLayout {
                Layout.fillWidth: true
                Text {
                    Layout.fillWidth: true
                    text: "Control center"
                    color: Theme.text
                    font.family: Theme.uiFont
                    font.pixelSize: 18
                    font.bold: true
                }
                Text {
                    text: Theme.lightMode ? "Light" : "Dark"
                    color: Theme.muted
                    font.family: Theme.monoFont
                    font.pixelSize: 12
                    MouseArea {
                        anchors.fill: parent
                        onClicked: Theme.lightMode = !Theme.lightMode
                    }
                }
            }

            GridLayout {
                Layout.fillWidth: true
                columns: 2
                columnSpacing: Theme.spaceSm
                rowSpacing: Theme.spaceSm
                Repeater {
                    model: [
                        { label: "Audio", command: ["wpctl", "set-mute", "@DEFAULT_AUDIO_SINK@", "toggle"] },
                        { label: "Network", command: ["foot", "-e", "nmtui"] },
                        { label: "Bluetooth", command: ["bluetoothctl", "power", "on"] },
                        { label: "Brightness +", command: ["brightnessctl", "set", "5%+"] },
                        { label: "Balanced", command: ["powerprofilesctl", "set", "balanced"] },
                        { label: "Lock", command: ["loginctl", "lock-session"] }
                    ]
                    delegate: Rectangle {
                        required property var modelData
                        Layout.fillWidth: true
                        implicitHeight: 58
                        radius: Theme.radiusMd
                        color: Theme.surfaceRaised
                        border.color: Theme.focus
                        border.width: 1
                        Text {
                            anchors.centerIn: parent
                            text: modelData.label
                            color: Theme.text
                            font.family: Theme.uiFont
                            font.pixelSize: 13
                        }
                        MouseArea {
                            anchors.fill: parent
                            onClicked: Quickshell.execDetached(modelData.command)
                        }
                    }
                }
            }

            Item { Layout.fillHeight: true }
            Text {
                Layout.fillWidth: true
                text: "All privileged actions go through the Hyprland polkit agent."
                wrapMode: Text.WordWrap
                color: Theme.muted
                font.family: Theme.uiFont
                font.pixelSize: 12
            }
        }
    }
}
