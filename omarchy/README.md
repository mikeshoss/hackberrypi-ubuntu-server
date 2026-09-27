# Omarchy on the HackberryPi CM5

[Omarchy](https://omarchy.org/) 4 is DHH's Arch Linux + Hyprland desktop. It installs from an x86_64 ISO
onto a wiped disk; there is no official ARM or Ubuntu version. `install-omarchy.sh` (in the repo root) gets
it onto this deck anyway, on Ubuntu, by filling each gap in turn.

## Run it

On the deck, over SSH, inside `tmux` (two phases take hours):

```bash
git clone https://github.com/mikeshoss/hackberrypi-ubuntu-server
cd hackberrypi-ubuntu-server
./install-omarchy.sh                          # gap report: what is missing, which phase fixes it
./install-omarchy.sh hardware && sudo reboot  # first, even on 24.04
./install-omarchy.sh all                      # the rest; stops after `os` while you are on 24.04
```

Run as your normal user; the script asks for `sudo` once and keeps it alive. Every phase can be run on its
own and re-run after a failure.

| Phase | What it fills | Time |
|---|---|---|
| `check` | Nothing — prints one row per requirement and the phase that fixes it | seconds |
| `hardware` | Pins the HackberryPi overlays in `/etc/flash-kernel/dtbs/overlays`, fixes `config.txt` in place, battery, power button | seconds + reboot |
| `os` | Ubuntu 26.04 LTS: `do-release-upgrade` when Canonical opens it, otherwise tells you to reflash | ~1 h or a reflash |
| `hyprland` | Rebuilds the `cppiber/hyprland` PPA's source packages for arm64 into a local apt repo; installs Hyprland 0.56, Quickshell, uwsm | 1–2 h (est.) |
| `omarchy` | Runs [omarchy-ubuntu](https://github.com/SebastienDenooz/omarchy-ubuntu) at a pinned commit, with arm64 versions of its x86-only steps | 1.5–3 h (est.) |
| `deck` | 720×720 scale, DRM card order, CapsLock, NetworkManager, start Omarchy on tty1 | seconds + reboot |

Options: `--scale=N` (default 1.25), `--autologin`, `--no-network-switch`, `--with-hyprmoncfg`,
`--dev-upgrade`, `--jobs=N`, `--yes`. `./install-omarchy.sh --help` for details.

After the `deck` phase and a reboot, log in on the deck's own keyboard: Omarchy starts on tty1.
<kbd>Super</kbd>+<kbd>Space</kbd> opens the Omarchy menu, <kbd>Super</kbd>+<kbd>Alt</kbd>+<kbd>Space</kbd> the apps
menu, <kbd>Super</kbd>+<kbd>Return</kbd> a terminal, and <kbd>Super</kbd>+<kbd>K</kbd> lists every binding.

## Changing keys and layouts

A key can be changed at four levels. Use the shallowest one that does the job.

| To change | Where | Reaches |
|---|---|---|
| What a physical key sends: move the digits, add F-keys, a second Super | Keyboard firmware, with **Vial** | Everything — console, Hyprland, any computer the keyboard is plugged into |
| Which language the keys type (`us`, `ca`, `us,fr`…) | **XKB layout**: `~/.config/hypr/input.lua`, and `/etc/default/keyboard` for the console | This OS |
| One key's meaning, without touching the firmware | **keyd** | Everything on the deck, console included |
| What a shortcut does | `~/.config/hypr/bindings.lua` | Hyprland |

### Firmware (Vial)

The keyboard is an RP2040 running Vial's QMK firmware, connected to the CM5 over USB. Changes are written to
the keyboard itself: they survive reinstalls and follow it to any computer.

- **From the deck:** the `deck` phase installs Vial's udev rule (`/etc/udev/rules.d/59-vial.rules`), so
  Chrome can open the keyboard: go to <https://vial.rocks> and pick it. This follows from the hardware (the
  keyboard is a USB device on the CM5) but has not been tried on a deck yet.
- **From another computer** (ZitaoTech's documented way): cable the computer to the deck's lower USB-C port and
  flip the left switch — the keyboard now talks to that computer. Open Vial there; flip back when done.
- **Undo everything:** in Vial, *File → Load saved layout* with your keyboard's stock `.vil` from
  [ZitaoTech/HackberryPiCM5/Keyboard](https://github.com/ZitaoTech/HackberryPiCM5/tree/main/Keyboard)
  (Q10, Q20 or 9900).
- **Careful:** one key on layer 2 enters the bootloader when double-tapped (tap dance 3 in the stock keymaps).
  The keyboard stops and a USB drive appears; reboot and it comes back.
- **Leave CapsLock as `KC_CAPS`:** the firmware switches the trackpad to scrolling from the CapsLock light.

### Layout (XKB)

In Hyprland, edit `~/.config/hypr/input.lua` (also *Setup → Input* in the Omarchy menu), then `hyprctl reload`;
`hyprctl configerrors` shows mistakes.

```lua
hl.config({
  input = {
    kb_layout = "us,ca",
    kb_variant = ",fr",
    kb_options = "shift:both_capslock_cancel",   -- never add compose:caps here: CapsLock drives trackpad scrolling
  },
})
```

- **Switching between layouts:** Omarchy's usual `grp:alts_toggle` needs two Alt keys and the deck has one. Bind a
  free combo in `~/.config/hypr/bindings.lua` instead:
  `o.bind("SUPER + CTRL + J", "Next keyboard layout", "hyprctl switchxkblayout all next")`
- **Only the built-in keyboard** (leave a USB keyboard alone): find its name with `hyprctl devices`, then
  `hl.device({ name = "<that name>", kb_layout = "ca" })`. `hl.device` also takes `kb_options` and `kb_file`
  (a complete custom XKB keymap).
- **Console and the default:** `sudo dpkg-reconfigure keyboard-configuration` writes `/etc/default/keyboard`,
  which the console uses and which the port's `input.lua` reads when you have not set `kb_layout` yourself.
- If `compose:caps` comes back (an Omarchy menu change, a copied example), `./install-omarchy.sh check` flags it
  and `./install-omarchy.sh deck` takes it out again, leaving your other options alone.

### One key without reflashing (keyd)

keyd remaps at the input-event level, under both the console and Hyprland. Ubuntu 26.04 packages it.

```bash
sudo apt install keyd
sudo keyd monitor                      # press keys: prints the keyboard's id and each key's name
sudo tee /etc/keyd/deck.conf >/dev/null <<'EOF'
[ids]
<the keyboard id keyd monitor printed>

[main]
leftcontrol = overload(control, esc)   # example: Ctrl when held, Escape when tapped
EOF
sudo systemctl enable --now keyd
```

Two things to check after enabling it: the trackpad's CapsLock scroll mode still works (if not, make the change in
Vial instead), and `hyprctl devices` now shows a keyd virtual keyboard — any `hl.device` block has to use that
name.

### Shortcuts

<kbd>Super</kbd>+<kbd>K</kbd> lists every binding. Change them in `~/.config/hypr/bindings.lua`: `hl.unbind("SUPER + X")`
removes one, `o.bind("SUPER + X", "What it does", "command")` adds one.

## Why each gap exists

- **Ubuntu 26.04 is the floor.** Omarchy 4's Hyprland 0.56 is configured in Lua 5.5, and its Quickshell
  desktop needs Qt 6.10. 24.04 has neither. As of September 2026, Ubuntu lists 26.04.1 but has not opened
  24.04 → 26.04 upgrades (`Supported: 0` in meta-release-lts): a fresh 26.04 flash is the clean path.
- **26.04 changes how the Pi boots.** Boot files move into `current/`, and each new kernel is staged in
  `new/` with only the overlays flash-kernel knows about. Overlays copied by hand into
  `/boot/firmware/overlays` are no longer read, and would vanish at the first kernel update even if they
  were. The `hardware` phase pins them where flash-kernel looks. `install-post-boot.sh` refuses to run on
  this layout, because rewriting `config.txt` would drop the `os_prefix=current/` line the firmware needs.
- **Nobody ships Hyprland 0.56 for arm64 Ubuntu.** The archive has 0.53.3; the PPA only builds amd64. Its
  packaging builds on arm64 unchanged, so the `hyprland` phase rebuilds it on the deck.
- **The port assumes x86.** Its Chrome step pins `arch=amd64` and its prebuilt-tools step downloads x86
  assets. `omarchy/kit-overrides/` replaces both with versions that pick the arm64 assets (all exist;
  Obsidian only as an AppImage, unpacked to `/opt/Obsidian` so Ubuntu's AppArmor profile keeps Electron's
  sandbox working).
- **Ubuntu Server is not a desktop.** No display manager (tty1 starts the session through uwsm), and
  networking is systemd-networkd while Omarchy's network panel speaks only to NetworkManager.
- **The deck is not a laptop.** The panel is 720×720 at ~255 ppi on its own RP1 DRM device; the GPU has no
  headroom for animations or blur; the keyboard firmware uses CapsLock to switch the trackpad to scrolling,
  where Omarchy would make it the Compose key.

## Not available on the deck

- **Screen recording** — gpu-screen-recorder encodes on the GPU, and the CM5 has no video encoder. Skipped.
- **Voxtype dictation** — amd64 only.
- **Compose key** — CapsLock stays CapsLock for the trackpad.

## Gotchas

- **Panel black under Hyprland, HDMI fine:** swap the DRM card order:
  `echo DECK_DRM_ORDER=hdmi-first > ~/.config/uwsm/env-hyprland.local`, log out, log back in.
- **Digits live on layer 1** of the stock VIAL keymap (the layer key that turns W E R into 1 2 3), so
  workspace 1 is <kbd>Super</kbd> + that layer key + <kbd>W</kbd>. Remap in VIAL if that is one finger too many.
- **The NetworkManager switch happens at reboot**, on purpose. Applying it live over SSH-on-Wi-Fi drops the
  session you are applying it from. To go back: delete `/etc/netplan/90-omarchy-deck-nm.yaml` and reboot.
- **Re-running the port's user-config step** (`--only=40` in its checkout) moves `~/.config/hypr` aside and
  copies Omarchy's fresh, which drops `deck.lua`. Run `./install-omarchy.sh deck` again afterwards;
  `./install-omarchy.sh check` shows when it is missing.
- **Updating Hyprland** means re-running `./install-omarchy.sh hyprland` after the PPA moves on; apt alone
  will not see new arm64 builds.
- **Build trees** in `~/.cache/omarchy-deck/hypr-build/` can be deleted once installed; the `.deb`s stay in
  `/var/local/omarchy-deck/debs/`.

## Tests

Both need Docker and change nothing on the host.

`omarchy/test/test-deck.sh` runs the `deck` phase twice with different options and checks the Lua parses,
nothing is added twice, the login hook goes where bash reads it, netplan takes the NetworkManager
renderer, and the DRM picker orders the cards correctly against a fake sysfs.

`omarchy/test/test-hardware.sh` runs the `hardware` phase in a throwaway Ubuntu 26.04 container (needs
Docker) against the deck's current 24.04 layout and a fresh 26.04 A/B layout produced by Ubuntu's own
`piboot-try` migration, then uses flash-kernel's own overlay search to prove the pinned overlays reach the
next kernel's boot slot. Behind a TLS-inspecting proxy, pass its CA: `EXTRA_CA=/path/ca.crt`.
