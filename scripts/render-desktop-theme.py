#!/usr/bin/env python3
"""Render all desktop colour consumers from the audited theme manifest."""

from __future__ import annotations

import argparse
import json
import math
import re
from pathlib import Path

COLOUR = re.compile(r"^#[0-9a-fA-F]{6}$")
REQUIRED_COLOURS = {
    "page",
    "surface",
    "surface_raised",
    "text",
    "muted",
    "accent",
    "accent_text",
    "focus",
    "success",
    "warning",
    "danger",
}


def fail(message: str) -> None:
    raise ValueError(message)


def relative_luminance(colour: str) -> float:
    channels = [int(colour[offset : offset + 2], 16) / 255 for offset in (1, 3, 5)]

    def linear(channel: float) -> float:
        return channel / 12.92 if channel <= 0.04045 else ((channel + 0.055) / 1.055) ** 2.4

    red, green, blue = (linear(channel) for channel in channels)
    return 0.2126 * red + 0.7152 * green + 0.0722 * blue


def contrast(foreground: str, background: str) -> float:
    first, second = sorted((relative_luminance(foreground), relative_luminance(background)), reverse=True)
    return (first + 0.05) / (second + 0.05)


def validate_theme(name: str, palette: dict[str, str]) -> None:
    missing = REQUIRED_COLOURS.difference(palette)
    if missing:
        fail(f"{name}: missing colours: {', '.join(sorted(missing))}")
    for token, colour in palette.items():
        if not isinstance(colour, str) or not COLOUR.fullmatch(colour):
            fail(f"{name}: {token} must be a #RRGGBB colour")

    requirements = (
        ("body on page", palette["text"], palette["page"], 4.5),
        ("body on surface", palette["text"], palette["surface"], 4.5),
        ("accent text", palette["accent_text"], palette["accent"], 4.5),
        ("muted on page", palette["muted"], palette["page"], 3.0),
        ("muted on surface", palette["muted"], palette["surface"], 3.0),
        ("focus on page", palette["focus"], palette["page"], 3.0),
        ("success on page", palette["success"], palette["page"], 3.0),
        ("warning on page", palette["warning"], palette["page"], 3.0),
        ("danger on page", palette["danger"], palette["page"], 3.0),
    )
    for label, foreground, background, minimum in requirements:
        ratio = contrast(foreground, background)
        if ratio + math.ulp(ratio) < minimum:
            fail(f"{name}: {label} contrast {ratio:.2f}:1 is below {minimum:.1f}:1")


def qml_theme(theme: dict[str, object]) -> str:
    dark = theme["dark"]
    light = theme["light"]
    fonts = theme["fonts"]
    spacing = theme["spacing"]
    radii = theme["radii"]
    motion = theme["motion"]
    lines = ["pragma Singleton", "", "import QtQuick", "", "QtObject {", "    property bool lightMode: false"]
    for token in sorted(REQUIRED_COLOURS):
        lines.append(
            f'    readonly property color {token}: lightMode ? "{light[token]}" : "{dark[token]}"'
        )
    lines.extend(
        [
            f'    readonly property string uiFont: "{fonts["ui"]}"',
            f'    readonly property string monoFont: "{fonts["mono"]}"',
        ]
    )
    for token, value in spacing.items():
        lines.append(f"    readonly property int space{token.title()}: {value}")
    for token, value in radii.items():
        lines.append(f"    readonly property int radius{token.title()}: {value}")
    for token, value in motion.items():
        lines.append(f"    readonly property int {token}: {value}")
    lines.append("}")
    return "\n".join(lines) + "\n"


def swaync_colours(palette: dict[str, str]) -> str:
    return "\n".join(f"@define-color {token} {palette[token]};" for token in sorted(REQUIRED_COLOURS)) + "\n"


def hyprlock_colours(palette: dict[str, str]) -> str:
    ordered = ("page", "surface", "surface_raised", "text", "muted", "accent", "focus", "success", "warning", "danger")
    return "\n".join(f"${token} = rgb({palette[token][1:]})" for token in ordered) + "\n"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--theme", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    theme = json.loads(args.theme.read_text(encoding="utf-8"))
    if not isinstance(theme, dict):
        fail("theme root must be an object")
    for section in ("dark", "light"):
        palette = theme.get(section)
        if not isinstance(palette, dict):
            fail(f"{section} palette must be an object")
        validate_theme(section, palette)
    for section in ("fonts", "spacing", "radii", "motion"):
        if not isinstance(theme.get(section), dict):
            fail(f"{section} must be an object")

    args.output.mkdir(parents=True, exist_ok=True)
    (args.output / "Theme.qml").write_text(qml_theme(theme), encoding="utf-8", newline="\n")
    (args.output / "swaync-colors.css").write_text(swaync_colours(theme["dark"]), encoding="utf-8", newline="\n")
    (args.output / "swaync-colors-light.css").write_text(swaync_colours(theme["light"]), encoding="utf-8", newline="\n")
    (args.output / "hyprlock.conf").write_text(hyprlock_colours(theme["dark"]), encoding="utf-8", newline="\n")


if __name__ == "__main__":
    main()
