#!/usr/bin/env bats

load ../helpers/load.bash

@test "desktop theme renderer emits contrast-checked generated consumers" {
  local theme_dir="$BATS_TEST_TMPDIR/theme"

  run python3 "$REPO_ROOT/scripts/render-desktop-theme.py" \
    --theme "$REPO_ROOT/config/desktop-theme.json" \
    --output "$theme_dir"

  [ "$status" -eq 0 ]
  grep -Fx '    readonly property color accent: lightMode ? "#17607d" : "#5e9db8"' "$theme_dir/Theme.qml"
  grep -Fx '@define-color accent #5e9db8;' "$theme_dir/swaync-colors.css"
  grep -Fx '$page = rgb(15181d)' "$theme_dir/hyprlock.conf"
  cmp "$theme_dir/Theme.qml" "$REPO_ROOT/payload/etc/skel/.config/quickshell/spawn-arch/Theme.qml"
  cmp "$theme_dir/swaync-colors.css" "$REPO_ROOT/payload/etc/skel/.config/swaync/swaync-colors.css"
  cmp "$theme_dir/hyprlock.conf" "$REPO_ROOT/payload/etc/skel/.config/hypr/theme/hyprlock.conf"
}

@test "bento shell, notifications, and wallpaper use the generated theme surface" {
  local shell="$REPO_ROOT/payload/etc/skel/.config/quickshell/spawn-arch/shell.qml"
  local qml_module="$REPO_ROOT/payload/etc/skel/.config/quickshell/spawn-arch/qmldir"
  local panel="$REPO_ROOT/payload/etc/skel/.config/quickshell/spawn-arch/Panel.qml"
  local controls="$REPO_ROOT/payload/etc/skel/.config/quickshell/spawn-arch/ControlCenter.qml"
  local style="$REPO_ROOT/payload/etc/skel/.config/swaync/style.css"
  local wallpaper="$REPO_ROOT/payload/etc/skel/.local/share/wallpapers/spawn-bento.png"

  grep -Fx 'import Quickshell.Hyprland' "$panel"
  grep -Fx 'singleton Theme 1.0 Theme.qml' "$qml_module"
  grep -Fx 'PanelWindow {' "$panel"
  grep -Fx 'PopupWindow {' "$controls"
  grep -Fq 'onClicked: Quickshell.execDetached(modelData.command)' "$controls"
  grep -Fx '@import url("swaync-colors.css");' "$style"
  grep -Fx 'preload = ~/.local/share/wallpapers/spawn-bento.png' \
    "$REPO_ROOT/payload/etc/skel/.config/hypr/hyprpaper.conf"
  [ -s "$wallpaper" ]
}
