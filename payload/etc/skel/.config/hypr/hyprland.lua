local mainMod = "SUPER"
local workspaces = {
  "name:code",
  "name:web",
  "name:agent",
  "name:comms",
  "name:game",
}

hl.monitor({ output = "", mode = "preferred", position = "auto", scale = "auto" })

hl.config({
  general = {
    gaps_in = 6,
    gaps_out = 10,
    border_size = 2,
    resize_on_border = true,
    layout = "dwindle",
  },
  decoration = {
    rounding = 12,
  },
  input = {
    kb_layout = "us,ru",
    kb_options = "grp:win_space_toggle",
    follow_mouse = 1,
    touchpad = {
      natural_scroll = false,
    },
  },
  misc = {
    force_default_wallpaper = -1,
    disable_hyprland_logo = true,
    disable_splash_rendering = true,
  },
})

hl.workspace_rule({ workspace = "name:code", default = true })
hl.workspace_rule({
  workspace = "name:game",
  gaps_in = 0,
  gaps_out = 0,
  no_rounding = true,
  no_border = true,
})

hl.bind(mainMod .. " + SPACE", hl.dsp.exec_cmd("hyprlauncher"))
hl.bind(mainMod .. " + RETURN", hl.dsp.exec_cmd("foot"))
hl.bind(mainMod .. " + E", hl.dsp.exec_cmd("thunar"))
hl.bind(mainMod .. " + Q", hl.dsp.window.close())
hl.bind(mainMod .. " + F", hl.dsp.window.fullscreen({ action = "toggle" }))
hl.bind(mainMod .. " + SHIFT + L", hl.dsp.exec_cmd("loginctl lock-session"))
hl.bind("Print", hl.dsp.exec_cmd("hyprshot -m region --clipboard-only"))

hl.bind(mainMod .. " + left", hl.dsp.focus({ direction = "left" }))
hl.bind(mainMod .. " + right", hl.dsp.focus({ direction = "right" }))
hl.bind(mainMod .. " + up", hl.dsp.focus({ direction = "up" }))
hl.bind(mainMod .. " + down", hl.dsp.focus({ direction = "down" }))
hl.bind(mainMod .. " + mouse_down", hl.dsp.focus({ workspace = "e+1" }))
hl.bind(mainMod .. " + mouse_up", hl.dsp.focus({ workspace = "e-1" }))

for index, workspace in ipairs(workspaces) do
  local key = tostring(index)
  hl.bind(mainMod .. " + " .. key, hl.dsp.focus({ workspace = workspace }))
  hl.bind(mainMod .. " + SHIFT + " .. key, hl.dsp.window.move({ workspace = workspace }))
end
