#!/bin/bash
# =============================================================================
# HackberryPi CM5 - Omarchy on Ubuntu (arm64) gap filler
# =============================================================================
# Omarchy is Arch + Hyprland for x86_64 PCs. This deck is a CM5 (arm64) running
# Ubuntu. This script fills the gaps between the two, in phases you can run one
# at a time. Every phase is idempotent: re-run it after a failure and it picks
# up where it stopped. See omarchy/README.md for the why behind each step.
#
# Run it as your normal user, from a checkout of this repo, inside tmux:
#   ./install-omarchy.sh                 read-only gap report (same as `check`)
#   ./install-omarchy.sh all             hardware → os → hyprland → omarchy → deck
#
# Phases:
#   check      what is missing on this deck, and which phase fixes it (changes nothing)
#   hardware   make the HackberryPi overlays survive kernel updates and Ubuntu 26.04's A/B boot
#   os         get to Ubuntu 26.04 LTS (Omarchy 4 needs Hyprland 0.56 → Lua 5.5 and Qt 6.10)
#   hyprland   build the Hyprland 0.56 stack for arm64 as local .debs (the PPA ships amd64 only)
#   omarchy    run the omarchy-ubuntu kit (pinned), with its x86-only steps swapped for arm64 ones
#   deck       720x720 panel, DRM device order, CapsLock, NetworkManager, start Omarchy on tty1
#   all        every phase above, in order; stops after `os` if a release upgrade is still needed
#
# Options:
#   --scale=N          internal panel scale (default 1.25 → 576x576 logical; 720/N must be whole)
#   --autologin        log in automatically on tty1 (off by default: anyone holding the deck is you)
#   --no-network-switch  leave netplan on systemd-networkd (Omarchy's Wi-Fi panel will not work)
#   --with-hyprmoncfg  also build the kit's multi-monitor manager (step 55)
#   --dev-upgrade      allow `do-release-upgrade -d` while Ubuntu has not opened 24.04 → 26.04 yet
#   --jobs=N           parallel compile jobs (default: min(cores, RAM/2 GB))
#   --yes              take every default, ask nothing
# =============================================================================

set -euo pipefail

# --- Pinned upstreams ---------------------------------------------------------
# The omarchy-ubuntu kit reproduces Omarchy 4 on Ubuntu 26.04 (amd64). Pinned to the commit this script
# was written against; it clones basecamp/omarchy at v4.0.3 itself.
KIT_URL=https://github.com/SebastienDenooz/omarchy-ubuntu.git
KIT_REF=4fe87254dd616c525ff75be7d7d1c87e439ea72e
HYPR_PPA=cppiber/hyprland          # Hyprland 0.56 for Ubuntu 26.04, amd64 binaries only → rebuilt here
QS_PPA=avengemedia/danklinux       # Quickshell 0.3.x, published for arm64
HYPR_MIN=0.56
# Source packages rebuilt from the PPA, in dependency order. glaze is left out on purpose: Ubuntu 26.04
# already ships the 7.0.2 Hyprland asks for. hyprlock/hypridle/hyprpaper are not used by Omarchy 4.
HYPR_SOURCES=(hyprutils hyprwayland-scanner aquamarine hyprlang hyprcursor hyprgraphics hyprwire udis86
  hyprland hyprtoolkit hyprland-guiutils hyprpicker hyprsunset xdg-desktop-portal-hyprland)
HYPR_BINARIES=(hyprland hyprland-guiutils hyprpicker hyprsunset xdg-desktop-portal-hyprland)
DECK_REPO_URL=https://github.com/mikeshoss/hackberrypi-ubuntu-server.git

# --- Paths --------------------------------------------------------------------
STATE_DIR=${XDG_STATE_HOME:-$HOME/.local/state}/omarchy-deck
DATA_DIR=${XDG_DATA_HOME:-$HOME/.local/share}/omarchy-deck
CACHE_DIR=${XDG_CACHE_HOME:-$HOME/.cache}/omarchy-deck
KIT_DIR=$DATA_DIR/omarchy-ubuntu
BUILD_ROOT=$CACHE_DIR/hypr-build
LOCAL_REPO=/var/local/omarchy-deck/debs
LOCAL_LIST=/etc/apt/sources.list.d/omarchy-deck-local.list
BOOT=/boot/firmware
PERSIST_OVERLAYS=/etc/flash-kernel/dtbs/overlays
NETPLAN_NM=/etc/netplan/90-omarchy-deck-nm.yaml
AUTOLOGIN_DROPIN=/etc/systemd/system/getty@tty1.service.d/omarchy-deck-autologin.conf
POWER_DROPIN=/etc/systemd/logind.conf.d/50-hackberrypi-power.conf
HACKBERRY_OVERLAYS=(hackberrypicm5.dtbo hyperpixel4.dtbo vc4-kms-dpi-hyperpixel4sq.dtbo)

# --- Output -------------------------------------------------------------------
GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; BLUE='\033[1;34m'; DIM='\033[2m'; NC='\033[0m'
say()  { printf "\n${BLUE}==> %s${NC}\n" "$*"; }
ok()   { printf "  ${GREEN}✓${NC} %s\n" "$*"; }
warn() { printf "  ${YELLOW}!${NC} %s\n" "$*" >&2; }
info() { printf "    %s\n" "$*"; }
die()  { printf "${RED}Error: %s${NC}\n" "$*" >&2; exit 1; }

# --- Options ------------------------------------------------------------------
PHASE=check
SCALE=1.25
AUTOLOGIN=0
NETWORK_SWITCH=1
WITH_HYPRMONCFG=0
DEV_UPGRADE=0
ASSUME_YES=0
JOBS=""
ORIG_ARGS=("$@")
for arg in "$@"; do
  case $arg in
    check|hardware|os|hyprland|omarchy|deck|all) PHASE=$arg ;;
    --scale=*) SCALE=${arg#*=} ;;
    --autologin) AUTOLOGIN=1 ;;
    --no-network-switch) NETWORK_SWITCH=0 ;;
    --with-hyprmoncfg) WITH_HYPRMONCFG=1 ;;
    --dev-upgrade) DEV_UPGRADE=1 ;;
    --jobs=*) JOBS=${arg#*=} ;;
    --yes|-y) ASSUME_YES=1 ;;
    -h|--help) awk '/^# =====/ {n++; next} n == 2 {sub(/^# ?/, ""); print} n >= 3 {exit}' "${BASH_SOURCE[0]:-$0}"; exit 0 ;;
    *) die "unknown argument: $arg (see --help)" ;;
  esac
done
[[ $SCALE =~ ^[0-9]+(\.[0-9]+)?$ ]] || die "--scale=$SCALE is not a number"
[[ -z $JOBS || $JOBS =~ ^[1-9][0-9]*$ ]] || die "--jobs=$JOBS is not a positive number"

# --- Find the rest of this repo -----------------------------------------------
# The script needs overlays/ and omarchy/ next to it. Run from a lone download or `curl | bash`, it
# fetches the repo (DECK_REPO_REF, default main) and re-runs itself from there.
SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || pwd)
if [[ ! -f $SELF_DIR/omarchy/deck/deck.lua || ! -d $SELF_DIR/overlays ]]; then
  command -v git >/dev/null || die "git is required: sudo apt-get install -y git"
  repo=$DATA_DIR/hackberrypi-ubuntu-server
  ref=${DECK_REPO_REF:-main}
  mkdir -p "$DATA_DIR"
  if [[ -d $repo/.git ]]; then
    git -C "$repo" fetch -q origin "$ref" && git -C "$repo" checkout -q FETCH_HEAD
  else
    git clone -q --branch "$ref" "$DECK_REPO_URL" "$repo"
  fi
  [[ -f $repo/install-omarchy.sh ]] || die "branch $ref of $DECK_REPO_URL has no install-omarchy.sh yet (set DECK_REPO_REF)"
  if { : </dev/tty; } 2>/dev/null; then exec bash "$repo/install-omarchy.sh" "${ORIG_ARGS[@]}" </dev/tty; fi
  exec bash "$repo/install-omarchy.sh" "${ORIG_ARGS[@]}"
fi
DECK_FILES=$SELF_DIR/omarchy

# --- Helpers ------------------------------------------------------------------
os_release() { ( . /etc/os-release 2>/dev/null; printf '%s' "${!1:-}" ); }
ver_ge() { dpkg --compare-versions "$1" ge "$2" 2>/dev/null; }
pkg_version() { dpkg-query -W -f='${Status} ${Version}\n' "$1" 2>/dev/null | awk '/install ok installed/ {print $4}' || true; }
pkg_installed() { [[ -n $(pkg_version "$1") ]]; }
is_tty() { { : </dev/tty; } 2>/dev/null; }
# No `cmd | grep -q` under pipefail: grep -q exits at the first match, the writer can die of SIGPIPE,
# and pipefail then reports the match as a failure.
in_group() { [[ " $(id -nG) " == *" $1 "* ]]; }
nm_connected() { command -v nmcli >/dev/null && nmcli -t -f TYPE,STATE device 2>/dev/null | grep -E '^(wifi|ethernet):connected' >/dev/null; }

confirm() { # confirm "question" [default y|n]
  local question=$1 default=${2:-n} reply
  if (( ASSUME_YES )) || ! is_tty; then [[ $default == y ]]; return; fi
  printf "  ${YELLOW}?${NC} %s [%s] " "$question" "$([[ $default == y ]] && echo Y/n || echo y/N)" >/dev/tty
  read -r reply </dev/tty || reply=""
  [[ -z $reply ]] && reply=$default
  [[ ${reply,,} == y || ${reply,,} == yes ]]
}

SUDO_KEEPER=""
keep_sudo() { # ask for the password once, then keep the timestamp fresh through multi-hour builds
  [[ -n $SUDO_KEEPER ]] && return 0
  sudo -v || die "sudo is required"
  ( while kill -0 $$ 2>/dev/null; do sudo -n -v 2>/dev/null || true; sleep 50; done ) &
  SUDO_KEEPER=$!
  trap 'kill "$SUDO_KEEPER" 2>/dev/null || true' EXIT
}

apt_install() { sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@"; }

ubuntu_ok() { # Ubuntu 26.04 LTS or newer
  [[ $(os_release ID) == ubuntu ]] && ver_ge "$(os_release VERSION_ID)" 26.04
}

is_pi() { tr -d '\0' 2>/dev/null </proc/device-tree/model | grep 'Raspberry Pi' >/dev/null; }
require_pi() {
  is_pi || die "this is not a Raspberry Pi ($(tr -d '\0' 2>/dev/null </proc/device-tree/model || echo 'no device tree'))"
  [[ -f $BOOT/config.txt ]] || die "$BOOT/config.txt not found — not a Raspberry Pi Ubuntu install"
}

boot_layout() { # legacy: everything in the root of the boot partition. piboot: Ubuntu 26.04's A/B layout
  if grep -q '^os_prefix=' "$BOOT/config.txt" 2>/dev/null || [[ -f $BOOT/current/state ]]; then
    echo piboot
  else
    echo legacy
  fi
}

live_overlay_dirs() { # the overlay directories the firmware will actually read
  if [[ $(boot_layout) == piboot ]]; then
    echo "$BOOT/current/overlays"
    [[ -d $BOOT/new ]] && echo "$BOOT/new/overlays"
  else
    echo "$BOOT/overlays"
  fi
  return 0
}

kernel_overlay_dir() { echo "/usr/lib/firmware/$(uname -r)/device-tree/overlays"; }

login_profile() { # the file a bash login shell actually reads: ~/.bash_profile shadows ~/.profile
  if [[ -f $HOME/.bash_profile ]]; then echo "$HOME/.bash_profile"; else echo "$HOME/.profile"; fi
}

config_has() { grep -qxE "[[:space:]]*$1[[:space:]]*" "$BOOT/config.txt" 2>/dev/null; }

drm_cards() { # "card1:vc4-drm card2:drm-rp1-dpi …"
  local c name drv out=()
  for c in /sys/class/drm/card*; do
    [[ -e $c ]] || continue
    name=${c##*/}
    [[ $name == *-* ]] && continue
    drv=$(basename "$(readlink -f "$c/device/driver" 2>/dev/null)" 2>/dev/null || true)
    out+=("$name:${drv:-?}")
  done
  echo "${out[*]:-none}"
}

dpi_status() {
  local s
  for s in /sys/class/drm/card*-DPI-*/status; do
    [[ -r $s ]] && { cat "$s"; return 0; }
  done
  echo missing
}

upgrade_offered() { # has Canonical opened LTS → LTS upgrades to 26.04 yet?
  curl -fsS --max-time 15 https://changelogs.ubuntu.com/meta-release-lts 2>/dev/null |
    awk '/^Dist: resolute/ {r=1} r && /^Supported:/ && !done {print $2; done=1}' | grep -x 1 >/dev/null
}

default_jobs() {
  local mem_gb cpus by_ram
  mem_gb=$(awk '/MemTotal/ {print int($2/1048576)}' /proc/meminfo)
  cpus=$(nproc)
  by_ram=$(( mem_gb / 2 )); (( by_ram < 1 )) && by_ram=1
  (( by_ram < cpus )) && echo "$by_ram" || echo "$cpus"
}

max_version() { # highest of the versions given on stdin, by Debian ordering
  local best="" v
  while read -r v; do
    [[ -z $v ]] && continue
    if [[ -z $best ]] || dpkg --compare-versions "$v" gt "$best"; then best=$v; fi
  done
  echo "$best"
}

# =============================================================================
# check — the gap report
# =============================================================================
GAPS=()
row() { # row ok|warn|gap AREA "message" [phase]
  local state=$1 area=$2 msg=$3 phase=${4:-}
  case $state in
    ok)   printf "  ${GREEN}✓${NC} %-10s %s\n" "$area" "$msg" ;;
    warn) printf "  ${YELLOW}!${NC} %-10s %s\n" "$area" "$msg" ;;
    info) printf "  ${DIM}·${NC} %-10s %s\n" "$area" "$msg" ;;
    gap)  printf "  ${RED}✗${NC} %-10s %s${phase:+ ${DIM}→ $phase${NC}}\n" "$area" "$msg"
          if [[ -n $phase && " ${GAPS[*]} " != *" $phase "* ]]; then GAPS+=("$phase"); fi ;;
  esac
  return 0
}

phase_check() {
  GAPS=()
  local model arch mem_gb free_gb root_src v layout ov d found cfg_missing line hv qs_v kit_done

  say "Platform"
  model=$(tr -d '\0' 2>/dev/null </proc/device-tree/model || echo unknown)
  case $model in
    *"Compute Module 5"*) row ok board "$model" ;;
    *"Raspberry Pi 5"*)   row warn board "$model — not a CM5, but the same BCM2712 SoC" ;;
    *)                    row gap board "$model — this script targets the HackberryPi CM5" ;;
  esac
  arch=$(dpkg --print-architecture 2>/dev/null || uname -m)
  [[ $arch == arm64 ]] && row ok arch "arm64" || row gap arch "$arch — expected arm64"
  mem_gb=$(awk '/MemTotal/ {printf "%.0f", $2/1048576}' /proc/meminfo)
  if (( mem_gb >= 8 )); then row ok memory "${mem_gb} GB"
  elif (( mem_gb >= 4 )); then row warn memory "${mem_gb} GB — builds will run with fewer jobs, Omarchy will be tight"
  else row gap memory "${mem_gb} GB — too little for Hyprland builds and a Chromium-based desktop"; fi
  root_src=$(findmnt -no SOURCE / 2>/dev/null || echo '?')
  [[ $root_src == /dev/nvme* ]] && row ok disk "root on $root_src" || row warn disk "root on $root_src — builds on SD are slow"
  free_gb=$(df -BG --output=avail / 2>/dev/null | tail -1 | tr -dc '0-9')
  (( ${free_gb:-0} >= 25 )) && row ok space "${free_gb} GB free on /" || row gap space "${free_gb:-?} GB free on / — want 25 GB for builds and packages"
  if [[ -n ${SSH_CONNECTION:-} && -z ${TMUX:-} && ${TERM:-} != screen* ]]; then
    row warn session "over SSH without tmux — a dropped connection kills a multi-hour phase"
  fi

  say "Ubuntu"
  v=$(os_release VERSION_ID)
  if ubuntu_ok; then
    row ok release "Ubuntu $v ($(os_release VERSION_CODENAME))"
  elif [[ $(os_release ID) == ubuntu ]]; then
    row gap release "Ubuntu $v — Omarchy 4 needs 26.04 (Hyprland 0.56 → Lua 5.5, shell → Qt 6.10)" os
    if upgrade_offered; then
      row info upgrade "do-release-upgrade to 26.04 is open"
    else
      row warn upgrade "Ubuntu has not opened 24.04 → 26.04 upgrades yet: reflash 26.04, or --dev-upgrade"
    fi
  else
    row gap release "$(os_release PRETTY_NAME) — this script targets Ubuntu" os
  fi

  say "HackberryPi hardware layer"
  if [[ -f $BOOT/config.txt ]]; then
    layout=$(boot_layout)
    [[ $layout == piboot ]] && row info boot "A/B layout (piboot-try): overlays load from current/overlays" \
                            || row info boot "legacy layout: overlays load from overlays/"
    cfg_missing=()
    for line in 'dtoverlay=hackberrypicm5' 'dtoverlay=vc4-kms-dpi-hyperpixel4sq' 'dtparam=spi=off' 'dtparam=i2c_arm=off' 'enable_uart=0'; do
      config_has "$line" || cfg_missing+=("$line")
    done
    (( ${#cfg_missing[@]} == 0 )) && row ok config.txt "display + keyboard overlays and GPIO settings present" \
                                  || row gap config.txt "missing: ${cfg_missing[*]}" hardware
    for ov in hackberrypicm5.dtbo vc4-kms-dpi-hyperpixel4sq.dtbo; do
      found=1
      while read -r d; do [[ -f $d/$ov ]] || found=0; done < <(live_overlay_dirs)
      (( found )) && row ok overlay "$ov on the boot partition" || row gap overlay "$ov not where the firmware reads it" hardware
    done
    if [[ -f $PERSIST_OVERLAYS/hackberrypicm5.dtbo ]]; then
      row ok persist "overlays pinned in $PERSIST_OVERLAYS (survive kernel updates)"
    else
      row gap persist "overlays not in $PERSIST_OVERLAYS — the next kernel (and the 26.04 upgrade) boots without them" hardware
    fi
  else
    row gap config.txt "$BOOT/config.txt not found" hardware
  fi
  case $(dpi_status) in
    connected) row ok display "DPI panel connected ($(drm_cards))" ;;
    missing)   row gap display "no DPI connector — the display overlay is not loaded ($(drm_cards))" hardware ;;
    *)         row warn display "DPI connector reports $(dpi_status) ($(drm_cards))" ;;
  esac
  if compgen -G '/sys/class/power_supply/*/capacity' >/dev/null; then
    row ok battery "$(cat /sys/class/power_supply/*/capacity 2>/dev/null | head -1)% (MAX17048)"
  else
    row gap battery "fuel gauge not bound (no /sys/class/power_supply/*/capacity)" hardware
  fi
  [[ -f /etc/udev/rules.d/99-power-button.rules ]] && row ok power "side power button tamed" \
                                                   || row gap power "side power button still reboots on a bump" hardware

  say "Graphics stack"
  hv=$(pkg_version hyprland)
  if [[ -n $hv ]] && ver_ge "$hv" "$HYPR_MIN"; then row ok hyprland "$hv"
  elif [[ -n $hv ]]; then row gap hyprland "$hv installed — Omarchy 4 needs $HYPR_MIN+ (Lua config)" hyprland
  else row gap hyprland "not installed (the $HYPR_PPA PPA has no arm64 build — rebuilt locally)" hyprland; fi
  qs_v=$(pkg_version quickshell)
  [[ -n $qs_v ]] && row ok quickshell "$qs_v" || row gap quickshell "not installed (Omarchy 4's whole shell runs on it)" hyprland
  pkg_installed uwsm && row ok uwsm "$(pkg_version uwsm)" || row gap uwsm "not installed" hyprland
  pkg_installed mesa-vulkan-drivers && row ok mesa "GL + Vulkan (v3d/v3dv)" || row gap mesa "mesa-vulkan-drivers missing" hyprland
  if [[ -e /dev/dri/renderD128 ]]; then
    [[ -r /dev/dri/renderD128 && -w /dev/dri/renderD128 ]] && row ok gpu "render node usable" \
      || row gap gpu "no access to /dev/dri/renderD128 (render group)" deck
  else
    row gap gpu "no /dev/dri/renderD128 — vc4-kms-v3d not loaded" hardware
  fi

  say "Omarchy"
  if [[ -e /usr/share/omarchy/version ]]; then
    row ok omarchy "/usr/share/omarchy → $(readlink -f /usr/share/omarchy) ($(git -C /usr/share/omarchy describe --tags --always 2>/dev/null || cat /usr/share/omarchy/version))"
  else
    row gap omarchy "not installed" omarchy
  fi
  if [[ -d $KIT_DIR/logs/done ]]; then
    kit_done=$(find "$KIT_DIR/logs/done" -type f | wc -l)
    row info kit "omarchy-ubuntu kit: $kit_done steps done ($KIT_DIR)"
  fi
  command -v google-chrome-stable >/dev/null && row ok browser "$(google-chrome-stable --version 2>/dev/null)" \
                                            || row gap browser "no Chromium-family browser (web apps, SUPER+SHIFT+Enter)" omarchy

  say "Deck session"
  if [[ -f $HOME/.config/hypr/deck.lua ]] && grep -q 'require("hypr.deck")' "$HOME/.config/hypr/hyprland.lua" 2>/dev/null; then
    row ok hypr "deck.lua loaded (scale $(grep -oE 'scale = [0-9.]+' "$HOME/.config/hypr/deck.lua" | head -1 | cut -d' ' -f3), animations off, CapsLock kept)"
  else
    row gap hypr "no deck overrides — panel at scale auto, CapsLock would stop the trackpad scroll mode" deck
  fi
  grep -qs '>>> omarchy-deck: DRM device order' "$HOME/.config/uwsm/env-hyprland" \
    && row ok drm "AQ_DRM_DEVICES picks the DPI panel's card at login" \
    || row gap drm "Hyprland may open the HDMI card and leave the panel black" deck
  if nm_connected; then
    row ok network "NetworkManager manages the network (Omarchy's Wi-Fi panel works)"
  elif [[ -e $NETPLAN_NM ]]; then
    row warn network "netplan switched to NetworkManager — takes effect at the next reboot"
  elif (( NETWORK_SWITCH )); then
    row gap network "systemd-networkd manages the network; Omarchy's Wi-Fi panel only speaks NetworkManager" deck
  else
    row warn network "systemd-networkd kept (--no-network-switch): Omarchy's Wi-Fi panel will be empty"
  fi
  grep -qs '>>> omarchy-deck: start Omarchy on tty1' "$(login_profile)" \
    && row ok launch "logging in on tty1 starts Omarchy" \
    || row gap launch "no display manager on Ubuntu Server: nothing starts Hyprland" deck
  if in_group render && in_group video; then
    row ok groups "video, render"
  else
    row gap groups "$(id -un) is not in video/render" deck
  fi

  echo
  if (( ${#GAPS[@]} == 0 )); then
    printf "${GREEN}No gaps found.${NC} Reboot if you have not since the last phase, then log in on tty1.\n"
  else
    local order=() p
    for p in hardware os hyprland omarchy deck; do [[ " ${GAPS[*]} " == *" $p "* ]] && order+=("$p"); done
    printf "${YELLOW}Gaps to fill:${NC} %s\n" "${order[*]}"
    printf "Next: ${BLUE}./install-omarchy.sh %s${NC}   (or ./install-omarchy.sh all)\n" "${order[0]}"
  fi
}

# =============================================================================
# hardware — the HackberryPi layer, made durable
# =============================================================================
# flash-kernel copies overlays onto the boot partition on every kernel install, from
# /etc/flash-kernel/dtbs first and the kernel package second. On Ubuntu 26.04 it stages each new
# kernel into new/ (tryboot) with only those overlays, so a hand-copied overlay is lost at the first
# kernel update: the deck boots, validation passes, and the panel and keyboard are gone. Pinning the
# HackberryPi overlays in /etc/flash-kernel/dtbs fixes that on both 24.04 and 26.04.
source_overlay() { # the copy of an overlay to pin: the one the deck boots with today, else this repo's
  local ov=$1 d
  while read -r d; do
    [[ -f $d/$ov ]] && { echo "$d/$ov"; return 0; }
  done < <(live_overlay_dirs)
  [[ -f $(kernel_overlay_dir)/$ov ]] && { echo "$(kernel_overlay_dir)/$ov"; return 0; }
  echo "$SELF_DIR/overlays/$ov"
}

ensure_config_txt() {
  local cfg=$BOOT/config.txt line missing=() block=()
  for line in 'dtoverlay=hackberrypicm5' 'dtoverlay=vc4-kms-dpi-hyperpixel4sq' 'dtparam=pciex1' \
              'dtparam=spi=off' 'dtparam=i2c_arm=off' 'enable_uart=0'; do
    config_has "$line" || missing+=("$line")
  done
  if (( ${#missing[@]} == 0 )); then ok "config.txt already has the HackberryPi settings"; return 1; fi

  sudo cp "$cfg" "$cfg.omarchy-deck-$(date +%Y%m%d-%H%M%S)"
  # Ubuntu's stock config turns these on; the DPI panel needs their GPIO pins.
  sudo sed -i -E 's/^[[:space:]]*dtparam=i2c_arm=on/dtparam=i2c_arm=off/; s/^[[:space:]]*dtparam=spi=on/dtparam=spi=off/; s/^[[:space:]]*enable_uart=1/enable_uart=0/' "$cfg"
  block=('[all]' '# HackberryPi CM5 — added by install-omarchy.sh. Order matters: the display overlay loads last.')
  config_has 'dtparam=i2c_arm=off' || block+=('dtparam=i2c_arm=off')
  config_has 'dtparam=spi=off'     || block+=('dtparam=spi=off')
  config_has 'enable_uart=0'       || block+=('enable_uart=0')
  if ! config_has 'dtoverlay=hackberrypicm5'; then
    block+=('dtoverlay=vc4-kms-v3d' 'dtoverlay=hackberrypicm5' 'dtparam=pciex1' 'dtoverlay=vc4-kms-v3d' 'dtoverlay=vc4-kms-dpi-hyperpixel4sq')
  else
    config_has 'dtparam=pciex1' || block+=('dtparam=pciex1')
    config_has 'dtoverlay=vc4-kms-dpi-hyperpixel4sq' || block+=('dtoverlay=vc4-kms-dpi-hyperpixel4sq')
  fi
  printf '\n%s\n' "${block[@]}" | sudo tee -a "$cfg" >/dev/null
  ok "config.txt: added ${missing[*]} (backup next to it)"
  return 0
}

phase_hardware() {
  say "HackberryPi hardware layer"
  require_pi
  keep_sudo
  local changed=0 ov src kdir d pinned
  kdir=$(kernel_overlay_dir)

  info "boot layout: $(boot_layout)"
  sudo install -d -m 755 "$PERSIST_OVERLAYS"
  for ov in "${HACKBERRY_OVERLAYS[@]}"; do
    src=$(source_overlay "$ov")
    [[ -f $src ]] || die "no copy of $ov found (looked on the boot partition, in $kdir and in $SELF_DIR/overlays)"
    pinned=$PERSIST_OVERLAYS/$ov
    if [[ $ov == vc4-kms-dpi-hyperpixel4sq.dtbo && -f $kdir/$ov ]] && cmp -s "$src" "$kdir/$ov"; then
      # The kernel ships this exact overlay: let flash-kernel keep following the kernel's copy.
      ok "$ov: the kernel package ships the same overlay, not pinned"
    elif ! cmp -s "$src" "$pinned"; then
      sudo install -m 644 "$src" "$pinned"; changed=1
      ok "$ov pinned in $PERSIST_OVERLAYS (from $src)"
    else
      ok "$ov already pinned"
    fi
    while read -r d; do
      if [[ ! -f $d/$ov ]]; then sudo install -D -m 644 "$src" "$d/$ov"; changed=1; ok "$ov copied to $d"; fi
    done < <(live_overlay_dirs)
  done

  ensure_config_txt && changed=1

  # Battery: the MAX17048 fuel gauge on I2C bus 15 needs binding at every boot (same as install-post-boot.sh).
  if ! grep -qs 'max17048 0x36' /etc/rc.local; then
    if [[ -f /etc/rc.local ]]; then
      sudo sed -i '/^exit 0/i modprobe max17040_battery\necho "max17048 0x36" > /sys/bus/i2c/devices/i2c-15/new_device' /etc/rc.local
    else
      printf '#!/bin/bash\nmodprobe max17040_battery\necho "max17048 0x36" > /sys/bus/i2c/devices/i2c-15/new_device\nexit 0\n' |
        sudo tee /etc/rc.local >/dev/null
    fi
    sudo chmod +x /etc/rc.local; changed=1
    ok "battery monitoring bound at boot (/etc/rc.local)"
  else
    ok "battery monitoring already set up"
  fi

  # Power button: udev keeps logind off it, and a drop-in (not sed on logind.conf, which Ubuntu 26.04 no
  # longer ships in /etc) makes every Handle*Key an ignore. Omarchy's own drop-in only covers the power key.
  if [[ ! -f /etc/udev/rules.d/99-power-button.rules ]]; then
    sudo install -d /etc/udev/rules.d
    printf '%s\n' 'ACTION=="remove", GOTO="power_button_end"' \
      'SUBSYSTEM=="input", ATTRS{name}=="pwr_button", ENV{SYSTEMD_IGNORE}="1"' \
      'LABEL="power_button_end"' | sudo tee /etc/udev/rules.d/99-power-button.rules >/dev/null
    changed=1; ok "power button udev rule"
  fi
  if [[ ! -f $POWER_DROPIN ]]; then
    sudo install -d /etc/systemd/logind.conf.d
    printf '%s\n' '# HackberryPi CM5: the side button is easy to bump (install-omarchy.sh)' '[Login]' \
      HandlePowerKey=ignore HandlePowerKeyLongPress=ignore HandleRebootKey=ignore HandleRebootKeyLongPress=ignore \
      HandleSuspendKey=ignore HandleSuspendKeyLongPress=ignore HandleHibernateKey=ignore HandleHibernateKeyLongPress=ignore \
      HandleLidSwitch=ignore HandleLidSwitchExternalPower=ignore HandleLidSwitchDocked=ignore |
      sudo tee "$POWER_DROPIN" >/dev/null
    changed=1; ok "logind ignores the power/reboot/suspend keys ($POWER_DROPIN)"
  fi

  if (( changed )); then
    warn "hardware layer changed — reboot before the next phase: sudo reboot"
  else
    ok "hardware layer already complete"
  fi
}

# =============================================================================
# os — Ubuntu 26.04 LTS
# =============================================================================
phase_os() {
  say "Ubuntu release"
  local v; v=$(os_release VERSION_ID)
  if ubuntu_ok; then ok "Ubuntu $v — nothing to do"; return 0; fi
  [[ $(os_release ID) == ubuntu && $v == 24.04 ]] || die "Ubuntu $v: only 24.04 → 26.04 is handled here"

  info "Omarchy 4 runs Hyprland 0.56 (Lua 5.5) and a Quickshell desktop (Qt 6.10). 24.04 has Qt 6.4 and no"
  info "Lua 5.5, and no PPA fixes that on arm64, so the deck has to move to 26.04 LTS first."
  # The 26.04 kernel is staged into new/ with only the overlays flash-kernel knows about: pin them first.
  phase_hardware

  if upgrade_offered; then
    say "Upgrade to 26.04"
    info "do-release-upgrade is interactive and takes about an hour. Keep the deck on its charger."
    confirm "Start sudo do-release-upgrade now?" n || { info "Later: sudo do-release-upgrade, then ./install-omarchy.sh all"; return 1; }
    # Straight to the terminal: the upgrader's own prompts do not survive this script's log pipe.
    # shellcheck disable=SC2024  # the redirect is to the user's own terminal, on purpose
    sudo do-release-upgrade </dev/tty >/dev/tty 2>&1
    return 1
  fi

  warn "Ubuntu has not opened LTS upgrades from 24.04 to 26.04 yet (meta-release-lts: Supported: 0)."
  info "Two ways forward:"
  info "  1. Clean install (recommended): flash Ubuntu Server 26.04 LTS to the NVMe with Raspberry Pi Imager,"
  info "     boot (the panel stays black), SSH in, clone this repo and run: ./install-omarchy.sh hardware"
  info "     then sudo reboot, then ./install-omarchy.sh all"
  info "  2. Upgrade anyway with the development path: ./install-omarchy.sh os --dev-upgrade"
  if (( DEV_UPGRADE )); then
    confirm "Run sudo do-release-upgrade -d (unsupported path, can leave the deck unbootable)?" n || return 1
    # shellcheck disable=SC2024
    sudo do-release-upgrade -d </dev/tty >/dev/tty 2>&1
  fi
  return 1
}

# =============================================================================
# hyprland — Hyprland 0.56 for arm64, rebuilt from the PPA's own packaging
# =============================================================================
# cppiber/hyprland publishes Hyprland 0.56 for 26.04 but builds amd64 only (Launchpad PPAs do not build
# arm64 unless the owner enables it). Its source packages build fine on arm64, so they are rebuilt here
# in dependency order into a local apt repository. apt then installs and upgrades them like any package.
refresh_local_repo() {
  (cd "$LOCAL_REPO" && sudo sh -c 'dpkg-scanpackages --multiversion . /dev/null > Packages 2>/dev/null')
  sudo apt-get update -qq -o Dir::Etc::sourcelist="$LOCAL_LIST" -o Dir::Etc::sourceparts=- -o APT::Get::List-Cleanup=0
}

phase_hyprland() {
  say "Hyprland $HYPR_MIN stack (arm64)"
  ubuntu_ok || die "needs Ubuntu 26.04 — run: ./install-omarchy.sh os"
  keep_sudo
  local jobs src ver marker work dir started c

  # The Ubuntu 26.04 Hyprland 0.53 stack names two libraries differently from the PPA with the same files.
  for c in libhyprcursor0 libudis86-0; do
    if pkg_installed "$c"; then
      warn "$c (Ubuntu's Hyprland 0.53 stack) conflicts with the PPA build"
      confirm "Remove Ubuntu's Hyprland 0.53 packages ($c and what depends on it)?" y || die "cannot continue with $c installed"
      sudo apt-get remove -y "$c"
    fi
  done

  apt_install software-properties-common dpkg-dev devscripts equivs fakeroot build-essential
  # -s: the sources are what gets built. Re-run when the PPA was added earlier without deb-src.
  if ! { apt-cache showsrc hyprland 2>/dev/null || true; } | grep -E '^Version: .*ppa' >/dev/null; then
    sudo add-apt-repository -y -s "ppa:$HYPR_PPA"
  fi
  grep -rqs "$QS_PPA" /etc/apt/sources.list.d/ || sudo add-apt-repository -y "ppa:$QS_PPA"
  sudo install -d "$LOCAL_REPO"
  echo "deb [trusted=yes] file:$LOCAL_REPO ./" | sudo tee "$LOCAL_LIST" >/dev/null
  [[ -f $LOCAL_REPO/Packages ]] || sudo touch "$LOCAL_REPO/Packages"
  sudo apt-get update -qq

  jobs=${JOBS:-$(default_jobs)}
  mkdir -p "$BUILD_ROOT"
  for src in "${HYPR_SOURCES[@]}"; do
    ver=$({ apt-cache showsrc "$src" 2>/dev/null || true; } | awk '/^Version:/ {print $2}' | max_version)
    [[ -n $ver ]] || die "no source package for $src — is the $HYPR_PPA deb-src line enabled?"
    marker=$BUILD_ROOT/.built-$src-$ver
    if [[ -f $marker ]]; then ok "$src $ver (already built)"; continue; fi
    say "Building $src $ver (jobs: $jobs)"
    work=$BUILD_ROOT/$src
    rm -rf "$work"; mkdir -p "$work"
    (cd "$work" && apt-get source -qq "$src=$ver" >/dev/null) || die "could not download the source of $src $ver"
    dir=$(find "$work" -mindepth 1 -maxdepth 1 -type d -print -quit)
    [[ -n $dir ]] || die "apt-get source $src=$ver unpacked nothing"
    sudo DEBIAN_FRONTEND=noninteractive apt-get build-dep -y -qq "$dir" >/dev/null ||
      die "build dependencies of $src could not be installed (see apt's message above)"
    started=$SECONDS
    if ! (cd "$dir" && DEB_BUILD_OPTIONS="nocheck parallel=$jobs" dpkg-buildpackage -b -uc -us >"$work/build.log" 2>&1); then
      tail -30 "$work/build.log"
      die "$src failed to build — full log: $work/build.log (re-run the phase to retry from here)"
    fi
    sudo cp "$work"/*.deb "$LOCAL_REPO/"
    refresh_local_repo
    touch "$marker"
    ok "$src built in $(( (SECONDS - started) / 60 )) min: $(find "$work" -maxdepth 1 -name '*.deb' -printf '%f ')"
  done

  say "Installing the Hyprland stack, Quickshell and the session pieces"
  apt_install "${HYPR_BINARIES[@]}" xdg-desktop-portal-gtk uwsm xdg-terminal-exec lua5.5 liblua5.5-0 quickshell \
    mesa-vulkan-drivers libgl1-mesa-dri libegl1 libgles2 dbus-user-session
  command -v qs >/dev/null || sudo ln -sfn "$(command -v quickshell)" /usr/local/bin/qs
  ok "Hyprland $(pkg_version hyprland) · Quickshell $(pkg_version quickshell) · uwsm $(pkg_version uwsm)"
  ver_ge "$(pkg_version hyprland)" "$HYPR_MIN" || die "installed Hyprland is older than $HYPR_MIN"
}

# =============================================================================
# omarchy — the omarchy-ubuntu kit, made to run on arm64
# =============================================================================
phase_omarchy() {
  say "Omarchy (omarchy-ubuntu kit @ ${KIT_REF:0:12})"
  ubuntu_ok || die "needs Ubuntu 26.04 — run: ./install-omarchy.sh os"
  ver_ge "$(pkg_version hyprland)" "$HYPR_MIN" 2>/dev/null || die "needs Hyprland $HYPR_MIN — run: ./install-omarchy.sh hyprland"
  (( EUID != 0 )) || die "run as your normal user; sudo is asked for when needed"
  keep_sudo

  if [[ -d $KIT_DIR/.git ]]; then
    git -C "$KIT_DIR" fetch -q origin 2>/dev/null || true
    git -C "$KIT_DIR" checkout -q -- scripts   # drop the overrides from a previous run before re-applying
  else
    mkdir -p "$DATA_DIR"
    git clone -q "$KIT_URL" "$KIT_DIR"
  fi
  git -C "$KIT_DIR" -c advice.detachedHead=false checkout -q "$KIT_REF"
  ok "kit checked out at $KIT_REF"

  # x86-only steps swapped for architecture-aware ones (same software, same versions).
  install -m 755 "$DECK_FILES/kit-overrides/15-chrome.sh" "$KIT_DIR/scripts/15-chrome.sh"
  install -m 755 "$DECK_FILES/kit-overrides/20-prebuilt.sh" "$KIT_DIR/scripts/20-prebuilt.sh"
  ok "arm64 overrides: 15-chrome (Chrome arm64 repo), 20-prebuilt (arm64 assets, Obsidian AppImage)"
  # Step 10 installs Hyprland from the PPA's amd64 binaries; the hyprland phase already did its job.
  mkdir -p "$KIT_DIR/logs/done"
  touch "$KIT_DIR/logs/done/10-ppa-hyprland"
  ok "step 10 (PPA Hyprland) marked done: provided by the hyprland phase"

  # gpu-screen-recorder encodes on the GPU (VAAPI/NVENC); the CM5 has no video encoder, so skip its build.
  export ONLY="omacalc omacut omawrite ttfx tzupdate share_picker nvim"
  local args=()
  (( WITH_HYPRMONCFG )) || args+=(--no-hyprmoncfg)
  (( ASSUME_YES )) && args+=(--defaults)
  is_tty && export KIT_INTERACTIVE=1
  info "running $KIT_DIR/install.sh ${args[*]} — about 1.5-3 h on the CM5 (Rust and Qt builds)"
  (cd "$KIT_DIR" && ./install.sh "${args[@]}")
  unset ONLY
  ok "Omarchy installed ($(git -C /usr/share/omarchy describe --tags --always 2>/dev/null || echo '?'))"
}

# =============================================================================
# deck — the parts no x86 laptop needs
# =============================================================================
replace_marked_block() { # replace_marked_block FILE MARKER-NAME CONTENT-FILE
  local file=$1 name=$2 content=$3 tmp
  tmp=$(mktemp)
  if [[ -f $file ]]; then
    awk -v s=">>> $name >>>" -v e="<<< $name <<<" 'index($0, s) {skip=1} !skip {print} index($0, e) {skip=0}' "$file" >"$tmp"
  fi
  cat "$content" >>"$tmp"
  mkdir -p "$(dirname "$file")"
  cat "$tmp" >"$file"
  rm -f "$tmp"
}

phase_deck() {
  say "Deck session"
  [[ -f $HOME/.config/hypr/hyprland.lua ]] || die "no ~/.config/hypr/hyprland.lua — run: ./install-omarchy.sh omarchy"
  awk -v s="$SCALE" 'BEGIN { if (s <= 0) exit 1; w = 720 / s; exit (w != int(w)) }' ||
    die "--scale=$SCALE: 720/$SCALE must be a whole number (try 1, 1.25, 1.5, 2)"
  keep_sudo
  local tmp user; user=$(id -un)

  # 1. Hyprland overrides for the panel, the keyboard and the GPU.
  sed "s/@SCALE@/$SCALE/" "$DECK_FILES/deck/deck.lua" >"$HOME/.config/hypr/deck.lua"
  if ! grep -q 'require("hypr.deck")' "$HOME/.config/hypr/hyprland.lua"; then
    if grep -q 'require("hypr.autostart")' "$HOME/.config/hypr/hyprland.lua"; then
      sed -i '/require("hypr.autostart")/a require("hypr.deck") -- HackberryPi CM5 overrides (install-omarchy.sh)' "$HOME/.config/hypr/hyprland.lua"
    else
      printf '\nrequire("hypr.deck") -- HackberryPi CM5 overrides (install-omarchy.sh)\n' >>"$HOME/.config/hypr/hyprland.lua"
    fi
  fi
  ok "$HOME/.config/hypr/deck.lua: DPI-1 at scale $SCALE ($(awk -v s="$SCALE" 'BEGIN {printf "%d", 720/s}')px logical), animations/blur off, CapsLock kept"

  # 2. Which DRM card Hyprland opens (the DPI panel lives on its own RP1 device).
  replace_marked_block "$HOME/.config/uwsm/env-hyprland" "omarchy-deck: DRM device order" "$DECK_FILES/deck/env-hyprland"
  ok "$HOME/.config/uwsm/env-hyprland: AQ_DRM_DEVICES worked out at login (DPI card first)"

  # 3. NetworkManager, which Omarchy's network panel talks to. Applied at the next boot, never live:
  #    switching renderers under an SSH session over Wi-Fi would cut the branch you are sitting on.
  if (( NETWORK_SWITCH )); then
    if nm_connected; then
      ok "NetworkManager already manages the network"
    elif [[ -e $NETPLAN_NM ]]; then
      ok "netplan already set to NetworkManager (reboot pending)"
    else
      apt_install network-manager
      printf '%s\n' '# install-omarchy.sh: hand every interface to NetworkManager (Omarchy network panel).' \
        '# Existing netplan Wi-Fi/Ethernet definitions carry over; delete this file to go back to networkd.' \
        'network:' '  version: 2' '  renderer: NetworkManager' | sudo tee "$NETPLAN_NM" >/dev/null
      sudo chmod 600 "$NETPLAN_NM"
      # `netplan get` parses and merges every file like boot will, without generate's daemon-reload.
      [[ $(sudo netplan get renderer 2>/dev/null) == NetworkManager ]] ||
        { sudo rm -f "$NETPLAN_NM"; die "netplan did not take the NetworkManager renderer — left networkd in place"; }
      ok "netplan renderer → NetworkManager ($NETPLAN_NM), takes effect at the next reboot"
    fi
  else
    warn "--no-network-switch: systemd-networkd kept, Omarchy's Wi-Fi panel will be empty"
  fi

  # 4. Ubuntu Server has no display manager: logging in on tty1 starts the Omarchy session.
  tmp=$(mktemp)
  cat >"$tmp" <<'PROFILE'
# >>> omarchy-deck: start Omarchy on tty1 >>>
# Written by install-omarchy.sh. Logging in on the deck's own screen (tty1) starts Hyprland through uwsm,
# the same way Omarchy's session file does. SSH logins and other TTYs are left alone. -g 0: Ubuntu Server
# boots to multi-user.target, and may-start would otherwise wait for a graphical.target that never comes.
if [ -z "${WAYLAND_DISPLAY:-}" ] && [ "${XDG_VTNR:-}" = 1 ] && command -v uwsm >/dev/null && uwsm check may-start -g 0 >/dev/null 2>&1; then
  exec uwsm start -g -1 -e -D Hyprland hyprland.desktop
fi
# <<< omarchy-deck: start Omarchy on tty1 <<<
PROFILE
  replace_marked_block "$(login_profile)" "omarchy-deck: start Omarchy on tty1" "$tmp"
  rm -f "$tmp"
  ok "$(login_profile): log in on tty1 → Omarchy"

  if (( AUTOLOGIN )); then
    sudo install -d "$(dirname "$AUTOLOGIN_DROPIN")"
    printf '[Service]\nExecStart=\nExecStart=-/sbin/agetty -o "-p -f -- \\\\u" --noclear --autologin %s %%I $TERM\n' "$user" |
      sudo tee "$AUTOLOGIN_DROPIN" >/dev/null
    sudo systemctl daemon-reload 2>/dev/null || true   # the reboot below picks it up regardless
    ok "tty1 logs in as $user automatically at the next boot ($AUTOLOGIN_DROPIN)"
  elif [[ -f $AUTOLOGIN_DROPIN ]]; then
    info "autologin left as it is ($AUTOLOGIN_DROPIN) — delete it to turn autologin off"
  fi

  # 5. GPU and backlight access for the session.
  if ! in_group render || ! in_group video; then
    sudo usermod -aG video,render "$user"
    ok "$user added to video, render (effective at next login)"
  fi

  echo
  printf "${GREEN}Deck session ready.${NC}\n"
  info "1. sudo reboot"
  info "2. log in on the deck's own keyboard — Omarchy starts on tty1"
  info "3. SUPER+SPACE launcher · SUPER+ALT+SPACE Omarchy menu · SUPER+K every binding"
  info "   The default keymap has a GUI (Super) key on the base layer; digits need the Sym layer,"
  info "   so workspace 1 is Super + Sym + W. Remap in VIAL if that is too many fingers."
  info "If the panel stays black but HDMI works: echo 'DECK_DRM_ORDER=hdmi-first' > ~/.config/uwsm/env-hyprland.local"
}

# =============================================================================
main() {
  (( EUID != 0 )) || [[ $PHASE == check ]] || die "run as your normal user, not root (sudo is asked for when needed)"
  mkdir -p "$STATE_DIR/logs"
  case $PHASE in
    check)    phase_check ;;
    hardware) phase_hardware ;;
    os)       phase_os ;;
    hyprland) phase_hyprland ;;
    omarchy)  phase_omarchy ;;
    deck)     phase_deck ;;
    all)
      phase_hardware
      phase_os || { warn "stopped: finish the move to 26.04, reboot, then run ./install-omarchy.sh all again"; exit 0; }
      phase_hyprland
      phase_omarchy
      phase_deck
      phase_check
      ;;
  esac
}

# Sourced (omarchy/test/): define everything, run nothing.
[[ ${BASH_SOURCE[0]} == "$0" ]] || return 0

LOG=$STATE_DIR/logs/$PHASE-$(date +%Y%m%d-%H%M%S).log
mkdir -p "$STATE_DIR/logs"
if [[ $PHASE == check ]]; then
  main
else
  echo "Log: $LOG"
  main 2>&1 | tee "$LOG"
  exit "${PIPESTATUS[0]}"
fi
