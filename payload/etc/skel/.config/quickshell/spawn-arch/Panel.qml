import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Hyprland
import Quickshell.Services.Pipewire
import Quickshell.Services.SystemTray
import Quickshell.Widgets
import "."

PanelWindow {
    id: root
    anchors {
        top: true
        left: true
        right: true
    }
    exclusiveZone: 48
    implicitHeight: 48
    color: "transparent"
    property string clockText: Qt.formatDateTime(new Date(), "ddd, HH:mm")

    Timer {
        interval: 1000
        running: true
        repeat: true
        onTriggered: root.clockText = Qt.formatDateTime(new Date(), "ddd, HH:mm")
    }

    Rectangle {
        anchors.fill: parent
        anchors.margins: Theme.spaceSm
        radius: Theme.radiusMd
        color: Theme.surface
        border.color: Theme.focus
        border.width: 1

        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: Theme.spaceMd
            anchors.rightMargin: Theme.spaceMd
            spacing: Theme.spaceSm

            RowLayout {
                spacing: Theme.spaceXs
                Repeater {
                    model: Hyprland.workspaces
                    delegate: Rectangle {
                        required property HyprlandWorkspace modelData
                        implicitWidth: workspaceLabel.implicitWidth + Theme.spaceMd
                        implicitHeight: 28
                        radius: Theme.radiusSm
                        color: modelData.active ? Theme.accent : Theme.surfaceRaised
                        Text {
                            id: workspaceLabel
                            anchors.centerIn: parent
                            color: modelData.active ? Theme.accent_text : Theme.text
                            font.family: Theme.uiFont
                            font.pixelSize: 12
                            text: modelData.name ? modelData.name.replace("name:", "") : modelData.id
                        }
                        MouseArea {
                            anchors.fill: parent
                            onClicked: modelData.activate()
                        }
                    }
                }
            }

            Item { Layout.fillWidth: true }

            Text {
                color: Theme.muted
                font.family: Theme.monoFont
                font.pixelSize: 12
                text: Pipewire.defaultAudioSink ? "VOL" : "—"
            }

            RowLayout {
                spacing: Theme.spaceXs
                Repeater {
                    model: SystemTray.items
                    delegate: Item {
                        required property var modelData
                        implicitWidth: 20
                        implicitHeight: 20
                        IconImage {
                            anchors.centerIn: parent
                            implicitSize: 18
                            source: modelData.icon
                        }
                        MouseArea {
                            anchors.fill: parent
                            onClicked: modelData.activate()
                        }
                    }
                }
            }

            Rectangle {
                implicitWidth: clock.implicitWidth + Theme.spaceLg
                implicitHeight: 28
                radius: Theme.radiusSm
                color: Theme.surfaceRaised
                Text {
                    id: clock
                    anchors.centerIn: parent
                    color: Theme.text
                    font.family: Theme.uiFont
                    font.pixelSize: 12
                    text: root.clockText
                }
                MouseArea {
                    anchors.fill: parent
                    onClicked: controls.visible = !controls.visible
                }
            }
        }
    }

    ControlCenter {
        id: controls
        panel: root
    }
}
