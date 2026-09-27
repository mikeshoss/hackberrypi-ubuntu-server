#!/bin/bash
# Exercises install-omarchy.sh's `hardware` phase against a fake boot partition, in a throwaway
# Ubuntu 26.04 container — the layout the deck has on 24.04 today, and the A/B layout 26.04 ships.
# Ubuntu's own piboot-try package supplies the 26.04 config.txt migration, and its flash-kernel
# functions prove that pinned overlays reach new/ on the next kernel install.
#
# Usage: omarchy/test/test-hardware.sh          (needs docker; nothing on the host is touched)
set -euo pipefail

REPO=$(cd "$(dirname "$0")/../.." && pwd)
if [[ ${1:-} != --inside ]]; then
  # The phase does not care about the CPU: run the container natively, whatever ubuntu:26.04 was last pulled as.
  case $(uname -m) in aarch64|arm64) platform=linux/arm64 ;; *) platform=linux/amd64 ;; esac
  extra=()
  # Behind a TLS-inspecting proxy, hand its CA to the container (EXTRA_CA=/path/to/ca.crt).
  [[ -n ${EXTRA_CA:-} ]] && extra+=(-v "$EXTRA_CA:/usr/local/share/ca-certificates/extra.crt:ro")
  exec docker run --rm --platform "$platform" "${extra[@]}" -v "$REPO:/repo:ro" ubuntu:26.04 \
    bash /repo/omarchy/test/test-hardware.sh --inside
fi

# --- Inside the container (root, disposable) -----------------------------------------------------
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq && apt-get install -y -qq sudo curl ca-certificates >/dev/null
update-ca-certificates >/dev/null 2>&1 || true
useradd -m deck && echo 'deck ALL=(ALL) NOPASSWD:ALL' >/etc/sudoers.d/deck

# piboot-try is only built for arm64, but its scripts are shell and awk: unpack the .deb directly.
PIBOOT=/opt/piboot
curl -fsS -o /tmp/Packages.gz http://ports.ubuntu.com/ubuntu-ports/dists/resolute/main/binary-arm64/Packages.gz
pool=$(gzip -dc /tmp/Packages.gz | awk '/^Package: piboot-try$/ {p=1} p && /^Filename:/ && !done {print $2; done=1}')
curl -fsS -o /tmp/piboot.deb "http://ports.ubuntu.com/ubuntu-ports/$pool"
dpkg-deb -x /tmp/piboot.deb "$PIBOOT"
MIGRATE=$PIBOOT/usr/share/flash-kernel/migrate-config

BOOT=/boot/firmware
KVER=$(uname -r)
KOVL=/usr/lib/firmware/$KVER/device-tree/overlays
PINS=/etc/flash-kernel/dtbs/overlays

failures=0
pass() { printf '  \033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '  \033[0;31mFAIL\033[0m %s\n' "$*"; failures=$((failures + 1)); }
check() { local desc=$1; shift; if "$@"; then pass "$desc"; else fail "$desc"; fi; }

run_hardware() { # run the phase as the deck user, the way the script is meant to run
  local out
  if ! out=$(su deck -c 'bash -c "source /repo/install-omarchy.sh; is_pi() { return 0; }; phase_hardware"' 2>&1); then
    printf '%s\n' "$out" >&2
    fail "hardware phase exited with an error"
  fi
  printf '%s\n' "$out"
}
run_check() {
  su deck -c 'bash -c "source /repo/install-omarchy.sh; is_pi() { return 0; }; phase_check"' 2>&1 || true
}

reset_system() {
  rm -rf "$BOOT" "$PINS" /etc/rc.local /etc/udev/rules.d/99-power-button.rules /etc/systemd/logind.conf.d
  mkdir -p "$BOOT" "$KOVL"
  # The kernel package ships the stock HyperPixel4 Square overlay, byte-identical to this repo's copy.
  cp /repo/overlays/vc4-kms-dpi-hyperpixel4sq.dtbo "$KOVL/"
}

# A 24.04 Ubuntu Server config.txt as Raspberry Pi Imager writes it (the parts that matter here).
stock_config() {
  cat <<'CFG'
[all]
kernel=vmlinuz
cmdline=cmdline.txt
initramfs initrd.img followkernel

[pi4]
max_framebuffers=2
arm_boost=1

[all]
dtparam=audio=on
dtparam=i2c_arm=on
dtparam=spi=on
disable_overscan=1
enable_uart=1
camera_auto_detect=1
display_auto_detect=1
arm_64bit=1
dtoverlay=dwc2

[pi4]
dtoverlay=vc4-kms-v3d
max_framebuffers=2

[cm5]
dtoverlay=dwc2,dr_mode=host

[all]
CFG
}

echo "== 1. Ubuntu 24.04 deck, set up by install-post-boot.sh (legacy layout)"
reset_system
mkdir -p "$BOOT/overlays"
cp /repo/config.txt "$BOOT/config.txt"
cp /repo/overlays/*.dtbo "$BOOT/overlays/"
out=$(run_hardware)
check "config.txt left untouched" cmp -s /repo/config.txt "$BOOT/config.txt"
check "hackberrypicm5.dtbo pinned for flash-kernel" test -f "$PINS/hackberrypicm5.dtbo"
check "hyperpixel4.dtbo pinned for flash-kernel" test -f "$PINS/hyperpixel4.dtbo"
check "stock hyperpixel4sq overlay not pinned (kernel ships the same file)" test ! -e "$PINS/vc4-kms-dpi-hyperpixel4sq.dtbo"
check "battery bound in rc.local" grep -q 'max17048 0x36' /etc/rc.local
check "power button udev rule" test -f /etc/udev/rules.d/99-power-button.rules
check "logind drop-in ignores the power key" grep -qx 'HandlePowerKey=ignore' /etc/systemd/logind.conf.d/50-hackberrypi-power.conf
check "phase asks for a reboot" grep -q 'reboot before the next phase' <<<"$out"
out=$(run_hardware)
check "second run changes nothing" grep -q 'hardware layer already complete' <<<"$out"

echo "== 2. Deck booting a customised HyperPixel4 Square overlay"
printf 'custom' >>"$BOOT/overlays/vc4-kms-dpi-hyperpixel4sq.dtbo"
run_hardware >/dev/null
check "the overlay the deck boots with is pinned, so kernel updates cannot replace it" \
  cmp -s "$BOOT/overlays/vc4-kms-dpi-hyperpixel4sq.dtbo" "$PINS/vc4-kms-dpi-hyperpixel4sq.dtbo"

echo "== 3. Fresh Ubuntu 26.04 flash (A/B layout, stock config, no HackberryPi overlays)"
reset_system
stock_config | awk -f "$MIGRATE" >"$BOOT/config.txt"
mkdir -p "$BOOT/current/overlays"
echo good >"$BOOT/current/state"
cp "$KOVL/vc4-kms-dpi-hyperpixel4sq.dtbo" "$BOOT/current/overlays/"
run_hardware >/dev/null
check "os_prefix=current/ still leads config.txt" test "$(sed -n 2p "$BOOT/config.txt")" = "os_prefix=current/"
check "[tryboot] os_prefix=new/ kept" grep -qx 'os_prefix=new/' "$BOOT/config.txt"
check "I2C, SPI and UART no longer claim the panel's pins" bash -c "! grep -qE '^(dtparam=i2c_arm=on|dtparam=spi=on|enable_uart=1)' $BOOT/config.txt"
check "i2c_arm, spi and uart set off" bash -c "grep -qx 'dtparam=i2c_arm=off' $BOOT/config.txt && grep -qx 'dtparam=spi=off' $BOOT/config.txt && grep -qx 'enable_uart=0' $BOOT/config.txt"
check "display overlay is the last overlay loaded" test "$(grep '^dtoverlay=' "$BOOT/config.txt" | tail -1)" = "dtoverlay=vc4-kms-dpi-hyperpixel4sq"
check "keyboard overlay loads before the display overlay" bash -c "
  k=\$(grep -n '^dtoverlay=hackberrypicm5' $BOOT/config.txt | cut -d: -f1)
  d=\$(grep -n '^dtoverlay=vc4-kms-dpi-hyperpixel4sq' $BOOT/config.txt | tail -1 | cut -d: -f1)
  (( k < d ))"
check "hackberrypicm5.dtbo copied where the firmware reads it (current/overlays)" test -f "$BOOT/current/overlays/hackberrypicm5.dtbo"
check "nothing written to the legacy overlays/ directory" test ! -e "$BOOT/overlays"
check "backup of config.txt kept" bash -c "compgen -G '$BOOT/config.txt.omarchy-deck-*' >/dev/null"
before=$(md5sum "$BOOT/config.txt")
out=$(run_hardware)
check "second run leaves config.txt alone" test "$before" = "$(md5sum "$BOOT/config.txt")"
check "second run reports nothing to do" grep -q 'hardware layer already complete' <<<"$out"

echo "== 4. Next kernel install (flash-kernel's pi-try method staging new/)"
staged=$(
  set +eu   # flash-kernel's functions are written for plain sh, not for set -eu
  FK_DIR=$PIBOOT/usr/share/flash-kernel
  . "$FK_DIR/functions-piboot"
  find_device_tree_overlays /etc/flash-kernel/dtbs "/usr/lib/firmware/$KVER/device-tree"
)
check "new/overlays would receive hackberrypicm5.dtbo" grep -q "$PINS/hackberrypicm5.dtbo" <<<"$staged"
check "new/overlays would receive hyperpixel4.dtbo" grep -q "$PINS/hyperpixel4.dtbo" <<<"$staged"
check "new/overlays would receive the kernel's hyperpixel4sq overlay" grep -q "$KOVL/vc4-kms-dpi-hyperpixel4sq.dtbo" <<<"$staged"

echo "== 5. Gap report after the hardware phase"
report=$(run_check)
check "check: config.txt row passes" grep -q '✓.*config.txt' <<<"$report"
check "check: overlays row passes" grep -q '✓.*overlay .*hackberrypicm5.dtbo' <<<"$report"
check "check: persistence row passes" grep -q '✓.*persist' <<<"$report"

echo
if (( failures )); then echo "$failures check(s) failed"; exit 1; fi
echo "all checks passed"
