pragma Singleton

import QtQuick

QtObject {
    property bool lightMode: false
    readonly property color accent: lightMode ? "#17607d" : "#5e9db8"
    readonly property color accent_text: lightMode ? "#ffffff" : "#0a1218"
    readonly property color danger: lightMode ? "#a32638" : "#c43a4f"
    readonly property color focus: lightMode ? "#17607d" : "#5e9db8"
    readonly property color muted: lightMode ? "#4c5c66" : "#b4c0c7"
    readonly property color page: lightMode ? "#f6f8fa" : "#15181d"
    readonly property color success: lightMode ? "#236844" : "#2e7d58"
    readonly property color surface: lightMode ? "#ffffff" : "#1c242b"
    readonly property color surface_raised: lightMode ? "#e7edf1" : "#28363f"
    readonly property color text: lightMode ? "#18242c" : "#eef4f7"
    readonly property color warning: lightMode ? "#7a5000" : "#8a5a00"
    readonly property string uiFont: "Inter"
    readonly property string monoFont: "JetBrains Mono"
    readonly property int spaceXs: 4
    readonly property int spaceSm: 8
    readonly property int spaceMd: 12
    readonly property int spaceLg: 16
    readonly property int spaceXl: 24
    readonly property int radiusSm: 8
    readonly property int radiusMd: 12
    readonly property int radiusLg: 18
    readonly property int fast_ms: 120
    readonly property int normal_ms: 180
}
