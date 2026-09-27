-- HackberryPi CM5 overrides for Omarchy — written by install-omarchy.sh (deck phase).
-- Loaded last from ~/.config/hypr/hyprland.lua, so it wins over Omarchy's defaults and the kit's files.
-- Re-running the deck phase rewrites this file; put personal changes in looknfeel.lua / input.lua instead,
-- or delete the require("hypr.deck") line in hyprland.lua to drop all of it.

-- The internal panel: a 4" 720x720 HyperPixel4 Square on the RP1 DPI port (~255 ppi).
-- Scale 1 makes text unreadably small; 1.5 leaves a 480px-wide desktop the Omarchy bar cannot fit.
-- @SCALE@ is chosen at install time (--scale=, default 1.25 → a 576x576 logical desktop).
hl.monitor({ output = "DPI-1", mode = "preferred", position = "0x0", scale = @SCALE@ })
-- Anything plugged into the HDMI port sits to the right of the panel at its own preferred scale.
hl.monitor({ output = "", mode = "preferred", position = "auto-right", scale = "auto" })

-- Keyboard settings are deliberately not in here: layouts and kb_options belong in input.lua, where you
-- change them. (The deck phase only removes compose:caps there — the keyboard firmware reads the CapsLock
-- LED to switch the trackpad into scroll mode, so CapsLock has to stay CapsLock.)

hl.config({
  -- The CM5's VideoCore VII shares memory bandwidth with the CPU; animations, blur and shadows are the
  -- per-frame passes that make it feel slow (same defaults the Omarchy ARM ports ship for the Pi 5).
  animations = {
    enabled = false,
  },

  decoration = {
    rounding = 0,
    blur = {
      enabled = false,
    },
    shadow = {
      enabled = false,
    },
  },

  -- Omarchy's 5/10px gaps eat a noticeable share of a 576px-wide screen.
  general = {
    gaps_in = 2,
    gaps_out = 4,
  },
})
