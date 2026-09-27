#!/bin/bash
# Exercises install-omarchy.sh's `deck` phase and the uwsm DRM-card picker in a throwaway Ubuntu 26.04
# container: the Lua it writes parses, re-runs do not stack blocks, the login hook lands in the file bash
# actually reads, netplan accepts the NetworkManager switch, and the picker puts the DPI panel's card first.
#
# Usage: omarchy/test/test-deck.sh          (needs docker; EXTRA_CA=/path/ca.crt behind a TLS proxy)
set -euo pipefail

REPO=$(cd "$(dirname "$0")/../.." && pwd)
if [[ ${1:-} != --inside ]]; then
  case $(uname -m) in aarch64|arm64) platform=linux/arm64 ;; *) platform=linux/amd64 ;; esac
  extra=()
  [[ -n ${EXTRA_CA:-} ]] && extra+=(-v "$EXTRA_CA:/usr/local/share/ca-certificates/extra.crt:ro")
  exec docker run --rm --platform "$platform" "${extra[@]}" -v "$REPO:/repo:ro" ubuntu:26.04 \
    bash /repo/omarchy/test/test-deck.sh --inside
fi

# --- Inside the container (root, disposable) -----------------------------------------------------
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq && apt-get install -y -qq sudo ca-certificates lua5.4 netplan.io >/dev/null
update-ca-certificates >/dev/null 2>&1 || true
useradd -m -s /bin/bash deck && echo 'deck ALL=(ALL) NOPASSWD:ALL' >/etc/sudoers.d/deck

failures=0
pass() { printf '  \033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '  \033[0;31mFAIL\033[0m %s\n' "$*"; failures=$((failures + 1)); }
check() { local desc=$1; shift; if "$@"; then pass "$desc"; else fail "$desc"; fi; }
count() { grep -c -- "$1" "$2" 2>/dev/null || true; }

run_deck() { # run_deck [options…] — as the deck user, the way the script is meant to run
  local out
  if ! out=$(su deck -c "bash -c 'source /repo/install-omarchy.sh $*; phase_deck'" 2>&1); then
    printf '%s\n' "$out" >&2
    fail "deck phase exited with an error"
  fi
  printf '%s\n' "$out"
}

H=/home/deck
# What the omarchy phase leaves behind: Omarchy's hyprland.lua, which requires the user modules in order.
su deck -c "mkdir -p $H/.config/hypr && printf '%s\n' 'require(\"default.hypr.omarchy\")' 'require(\"hypr.monitors\")' 'require(\"hypr.autostart\")' 'require(\"default.hypr.toggles\")' > $H/.config/hypr/hyprland.lua"
# …and the port's input.lua, which sets Omarchy's kb_options explicitly.
cat >$H/.config/hypr/input.lua <<'LUA'
hl.config({
  input = {
    kb_layout = "us",
    -- CapsLock is Omarchy's compose key (emoji and ~/.XCompose shortcuts); both Shifts toggle Caps Lock.
    kb_options = "compose:caps,shift:both_capslock_cancel",
  },
})
LUA
chown deck:deck $H/.config/hypr/input.lua

echo "== 1. First run (default scale)"
run_deck >/dev/null
check "deck.lua written" test -f $H/.config/hypr/deck.lua
check "deck.lua is valid Lua" luac5.4 -p $H/.config/hypr/deck.lua
check "scale substituted (1.25)" grep -q 'output = "DPI-1".*scale = 1.25 ' $H/.config/hypr/deck.lua
check "no placeholder left" bash -c "! grep -q '@SCALE@' $H/.config/hypr/deck.lua"
check "hypr.deck required right after hypr.autostart" \
  test "$(grep -A1 'require("hypr.autostart")' $H/.config/hypr/hyprland.lua | tail -1 | cut -d' ' -f1)" = 'require("hypr.deck")'
check "uwsm env block written" grep -q 'AQ_DRM_DEVICES' $H/.config/uwsm/env-hyprland
check "login hook in ~/.profile (no ~/.bash_profile)" grep -q 'uwsm start -g -1' $H/.profile
check "may-start does not wait for graphical.target" grep -q 'uwsm check may-start -g 0' $H/.profile
check "netplan switched to NetworkManager" grep -q 'renderer: NetworkManager' /etc/netplan/90-omarchy-deck-nm.yaml
check "netplan file is root-only (netplan warns otherwise)" test "$(stat -c %a /etc/netplan/90-omarchy-deck-nm.yaml)" = 600
check "netplan's merged config now says NetworkManager" test "$(netplan get renderer)" = NetworkManager
check "deck in video and render" bash -c "id -nG deck | grep -qw render && id -nG deck | grep -qw video"
check "no autologin unless asked" test ! -e /etc/systemd/system/getty@tty1.service.d/omarchy-deck-autologin.conf
check "compose:caps taken out of input.lua" grep -q 'kb_options = "shift:both_capslock_cancel",' $H/.config/hypr/input.lua
check "comment mentioning compose left alone" grep -q "CapsLock is Omarchy's compose key" $H/.config/hypr/input.lua
check "no extra CapsLock block when input.lua has its own kb_options" bash -c "! grep -q 'omarchy-deck: CapsLock' $H/.config/hypr/input.lua"
check "input.lua is still valid Lua" luac5.4 -p $H/.config/hypr/input.lua
check "deck.lua leaves kb_options to input.lua" bash -c "! grep -vE '^[[:space:]]*--' $H/.config/hypr/deck.lua | grep -q kb_options"
check "Vial udev rule installed for the logged-in seat" grep -q 'vial:f64c2b3c.*TAG+="uaccess"' /etc/udev/rules.d/59-vial.rules

echo "== 2. Second run with other options"
su deck -c "echo '# user line' >> $H/.config/uwsm/env-hyprland"
run_deck --scale=1.5 --autologin >/dev/null
check "one require line, not two" test "$(count 'require("hypr.deck")' $H/.config/hypr/hyprland.lua)" = 1
check "one DRM block, not two" test "$(count '>>> omarchy-deck: DRM device order' $H/.config/uwsm/env-hyprland)" = 1
check "user's own env line kept" grep -q '^# user line' $H/.config/uwsm/env-hyprland
check "one login hook, not two" test "$(count '>>> omarchy-deck: start Omarchy on tty1' $H/.profile)" = 1
check "scale updated to 1.5" grep -q 'output = "DPI-1".*scale = 1.5 ' $H/.config/hypr/deck.lua
check "autologin drop-in names the user" grep -q -- '--autologin deck %I' /etc/systemd/system/getty@tty1.service.d/omarchy-deck-autologin.conf
check "autologin drop-in escapes \\u for systemd" grep -qF -- '-o "-p -f -- \\u"' /etc/systemd/system/getty@tty1.service.d/omarchy-deck-autologin.conf

echo "== 3. Keyboard options you set yourself survive"
sed -i 's/kb_options = "shift:both_capslock_cancel"/kb_options = "compose:caps,grp:ctrl_shift_toggle"/' $H/.config/hypr/input.lua
run_deck >/dev/null
check "compose:caps removed again, grp option kept" grep -q 'kb_options = "grp:ctrl_shift_toggle",' $H/.config/hypr/input.lua
report=$(su deck -c 'bash -c "source /repo/install-omarchy.sh; phase_check"' 2>&1 || true)
check "check: CapsLock row passes" grep -q '✓.*capslock' <<<"$report"
check "check: Vial row passes" grep -q '✓.*vial' <<<"$report"
# Omarchy's stock input.lua (everything commented) leaves kb_options to Omarchy's default, compose:caps included.
printf '%s\n' '-- Keep only your personal input overrides here.' '-- hl.config({ input = { kb_options = "compose:caps" } })' >$H/.config/hypr/input.lua
report=$(su deck -c 'bash -c "source /repo/install-omarchy.sh; phase_check"' 2>&1 || true)
check "check: flags Omarchy's default compose:caps" grep -q '✗.*capslock' <<<"$report"
run_deck >/dev/null
run_deck >/dev/null
check "no kb_options of your own: one CapsLock block added" test "$(count '>>> omarchy-deck: CapsLock stays CapsLock' $H/.config/hypr/input.lua)" = 1
check "…setting kb_options without compose:caps" grep -q 'kb_options = "shift:both_capslock_cancel"' $H/.config/hypr/input.lua
check "…and input.lua still parses" luac5.4 -p $H/.config/hypr/input.lua
sed -i '1i hl.config({ input = {\n    kb_options = "grp:ctrl_shift_toggle",\n} })' $H/.config/hypr/input.lua
run_deck >/dev/null
check "own kb_options added later: the CapsLock block steps aside" bash -c "! grep -q 'omarchy-deck: CapsLock' $H/.config/hypr/input.lua"

echo "== 4. Bad scale refused"
out=$(su deck -c "bash -c 'source /repo/install-omarchy.sh --scale=1.3; phase_deck'" 2>&1 || true)
check "720/1.3 is not whole: refused" grep -q 'must be a whole number' <<<"$out"

echo "== 5. ~/.bash_profile shadows ~/.profile"
su deck -c "echo '[ -f ~/.bashrc ] && . ~/.bashrc' > $H/.bash_profile"
run_deck >/dev/null
check "login hook lands in ~/.bash_profile" grep -q 'uwsm start -g -1' $H/.bash_profile

echo "== 6. DRM card picker (POSIX sh, fake sysfs)"
pick() { # pick FIXTURE-DIR [env-local-content] → prints AQ_DRM_DEVICES
  local fx=$1 local_env=${2:-} home
  home=$(mktemp -d); mkdir -p "$home/.config/uwsm"
  [[ -n $local_env ]] && printf '%s\n' "$local_env" >"$home/.config/uwsm/env-hyprland.local"
  sed "s#/sys/class/drm#$fx#g" /repo/omarchy/deck/env-hyprland >"$home/env"
  HOME=$home sh -c '. "$HOME/env"; printf "%s" "${AQ_DRM_DEVICES:-unset}"'
}
cm5=$(mktemp -d)   # what the deck exposes: v3d (no connectors), vc4 with two HDMI ports, RP1 DPI
mkdir -p "$cm5"/{card0,card1,card2,card1-HDMI-A-1,card1-HDMI-A-2,card2-DPI-1}
check "CM5: DPI card first, HDMI second" test "$(pick "$cm5")" = "/dev/dri/card2:/dev/dri/card1"
check "hdmi-first override honoured" test "$(pick "$cm5" 'DECK_DRM_ORDER=hdmi-first')" = "/dev/dri/card1:/dev/dri/card2"
check "explicit AQ_DRM_DEVICES in .local wins" test "$(pick "$cm5" 'export AQ_DRM_DEVICES=/dev/dri/card9')" = "/dev/dri/card9"
nodpi=$(mktemp -d); mkdir -p "$nodpi"/{card0,card1,card1-HDMI-A-1}
check "no DPI panel: left to Hyprland" test "$(pick "$nodpi")" = "unset"
swapped=$(mktemp -d); mkdir -p "$swapped"/{card0,card1,card2,card2-HDMI-A-1,card1-DPI-1}
check "probe order swapped at boot: still follows the panel" test "$(pick "$swapped")" = "/dev/dri/card1:/dev/dri/card2"

echo
if (( failures )); then echo "$failures check(s) failed"; exit 1; fi
echo "all checks passed"
