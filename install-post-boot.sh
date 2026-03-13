#!/bin/bash
# =============================================================================
# HackberryPi CM5 - Ubuntu Server Post-Boot Installer (Method 2: From SSH)
# =============================================================================
# Run this via SSH after booting Ubuntu Server on the HackberryPi CM5.
# The screen will be black when you first boot — that's expected.
# Find the device on your network and SSH in, then run this script.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/mikeshoss/hackberrypi-ubuntu-server/main/install-post-boot.sh | sudo bash
#   curl -fsSL https://raw.githubusercontent.com/mikeshoss/hackberrypi-ubuntu-server/main/install-post-boot.sh | sudo bash -s -- --power
# =============================================================================

set -e

POWER_TWEAKS=false
for arg in "$@"; do
    case $arg in
        --power) POWER_TWEAKS=true ;;
    esac
done

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo ""
echo "=========================================="
echo " HackberryPi CM5 - Ubuntu Server Setup"
echo " Method 2: Post-Boot (SSH)"
echo "=========================================="
if [ "$POWER_TWEAKS" = true ]; then
    echo -e " ${GREEN}Power optimizations: ENABLED${NC}"
fi
echo ""

# --- Check we're running as root ---
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Error: This script must be run as root (use sudo).${NC}"
    exit 1
fi

# --- Check we're on Ubuntu ---
if [ ! -f /boot/firmware/config.txt ]; then
    echo -e "${RED}Error: /boot/firmware/config.txt not found.${NC}"
    echo "This doesn't appear to be a Raspberry Pi Ubuntu Server installation."
    exit 1
fi

# --- Check overlays directory exists ---
if [ ! -d /boot/firmware/overlays ]; then
    echo -e "${RED}Error: /boot/firmware/overlays directory not found.${NC}"
    exit 1
fi

echo -e "${GREEN}✓${NC} Ubuntu Server detected"

# --- Download overlays ---
echo ""
echo "Downloading HackberryPi overlays..."

REPO_URL="https://raw.githubusercontent.com/mikeshoss/hackberrypi-ubuntu-server/main/overlays"

# hackberrypicm5.dtbo
if [ ! -f /boot/firmware/overlays/hackberrypicm5.dtbo ]; then
    wget -q -O /boot/firmware/overlays/hackberrypicm5.dtbo "${REPO_URL}/hackberrypicm5.dtbo"
    echo -e "${GREEN}✓${NC} hackberrypicm5.dtbo downloaded"
else
    echo -e "${GREEN}✓${NC} hackberrypicm5.dtbo already present"
fi

# hyperpixel4.dtbo
if [ ! -f /boot/firmware/overlays/hyperpixel4.dtbo ]; then
    wget -q -O /boot/firmware/overlays/hyperpixel4.dtbo "${REPO_URL}/hyperpixel4.dtbo"
    echo -e "${GREEN}✓${NC} hyperpixel4.dtbo downloaded"
else
    echo -e "${GREEN}✓${NC} hyperpixel4.dtbo already present"
fi

# vc4-kms-dpi-hyperpixel4sq.dtbo
if [ ! -f /boot/firmware/overlays/vc4-kms-dpi-hyperpixel4sq.dtbo ]; then
    ZITAO_URL="https://raw.githubusercontent.com/ZitaoTech/HackberryPiCM5/main/Operating%20System"
    wget -q -O /boot/firmware/overlays/vc4-kms-dpi-hyperpixel4sq.dtbo "${ZITAO_URL}/vc4-kms-dpi-hyperpixel4sq.dtbo"
    echo -e "${GREEN}✓${NC} vc4-kms-dpi-hyperpixel4sq.dtbo downloaded"
else
    echo -e "${GREEN}✓${NC} vc4-kms-dpi-hyperpixel4sq.dtbo already present"
fi

# --- Backup existing config.txt ---
echo ""
echo "Backing up config.txt..."
cp /boot/firmware/config.txt /boot/firmware/config.txt.backup
echo -e "${GREEN}✓${NC} Backup saved to config.txt.backup"

# --- Write config.txt ---
echo "Writing config.txt..."

tee /boot/firmware/config.txt > /dev/null << 'CONFIGEOF'
[all]
arm_64bit=1
kernel=vmlinuz
cmdline=cmdline.txt
initramfs initrd.img followkernel

# GPIO interfaces - SPI, I2C, and UART must be disabled to avoid
# pin conflicts with the HyperPixel4 DPI display.
# The hackberrypicm5 overlay handles these on alternate pins.
dtparam=audio=on
dtparam=i2c_arm=off
dtparam=spi=off

disable_overscan=1

#hdmi_drive=2

# Enable KMS graphics
dtoverlay=vc4-kms-v3d
disable_fw_kms_setup=1

# UART disabled - conflicts with DPI display on GPIO 14
enable_uart=0

camera_auto_detect=1
display_auto_detect=1

# USB controller
dtoverlay=dwc2

[pi4]
max_framebuffers=2
arm_boost=1

[pi3+]
dtoverlay=vc4-kms-v3d,cma-128

[pi02]
dtoverlay=vc4-kms-v3d,cma-128

[cm4]
dtoverlay=dwc2,dr_mode=host

[cm5]
dtoverlay=dwc2,dr_mode=host

# HackberryPi CM5 display and keyboard setup
# Order matters: hackberrypicm5 must load before the display overlay
[all]
dtoverlay=vc4-kms-v3d
dtoverlay=hackberrypicm5
dtparam=pciex1
dtoverlay=vc4-kms-v3d
dtoverlay=vc4-kms-dpi-hyperpixel4sq
CONFIGEOF

echo -e "${GREEN}✓${NC} config.txt written"

# --- Set up battery monitoring ---
echo ""
echo "Setting up battery monitoring..."

tee /etc/rc.local > /dev/null << 'RCEOF'
#!/bin/bash
modprobe max17040_battery
echo "max17048 0x36" > /sys/bus/i2c/devices/i2c-15/new_device
exit 0
RCEOF
chmod +x /etc/rc.local
echo -e "${GREEN}✓${NC} Battery monitoring configured"

# --- Configure power button ---
echo ""
echo "Configuring power button..."

mkdir -p /etc/udev/rules.d
tee /etc/udev/rules.d/99-power-button.rules > /dev/null << 'UDEVEOF'
ACTION=="remove", GOTO="power_button_end"
SUBSYSTEM=="input", ATTRS{name}=="pwr_button", ENV{SYSTEMD_IGNORE}="1"
LABEL="power_button_end"
UDEVEOF
echo -e "${GREEN}✓${NC} Power button udev rule configured"

# Disable power button in logind
sed -i 's/#HandlePowerKey=poweroff/HandlePowerKey=ignore/' /etc/systemd/logind.conf
sed -i 's/#HandlePowerKeyLongPress=ignore/HandlePowerKeyLongPress=ignore/' /etc/systemd/logind.conf
sed -i 's/#HandleRebootKey=reboot/HandleRebootKey=ignore/' /etc/systemd/logind.conf
sed -i 's/#HandleRebootKeyLongPress=poweroff/HandleRebootKeyLongPress=ignore/' /etc/systemd/logind.conf
sed -i 's/#HandleSuspendKey=suspend/HandleSuspendKey=ignore/' /etc/systemd/logind.conf
sed -i 's/#HandleSuspendKeyLongPress=suspend/HandleSuspendKeyLongPress=ignore/' /etc/systemd/logind.conf
sed -i 's/#HandleHibernateKey=hibernate/HandleHibernateKey=ignore/' /etc/systemd/logind.conf
sed -i 's/#HandleHibernateKeyLongPress=ignore/HandleHibernateKeyLongPress=ignore/' /etc/systemd/logind.conf
sed -i 's/#HandleLidSwitch=suspend/HandleLidSwitch=ignore/' /etc/systemd/logind.conf
sed -i 's/#HandleLidSwitchExternalPower=suspend/HandleLidSwitchExternalPower=ignore/' /etc/systemd/logind.conf
sed -i 's/#HandleLidSwitchDocked=ignore/HandleLidSwitchDocked=ignore/' /etc/systemd/logind.conf
systemctl restart systemd-logind
echo -e "${GREEN}✓${NC} Power button handlers disabled"

# --- Install gpm for mouse support in console ---
echo ""
echo "Installing console mouse support..."
apt-get install -y gpm > /dev/null 2>&1
systemctl enable gpm
echo -e "${GREEN}✓${NC} GPM installed for trackpad support"

# --- Power optimizations (optional) ---
if [ "$POWER_TWEAKS" = true ]; then
    echo ""
    echo "Applying power optimizations..."

    # Install cpufrequtils
    apt-get install -y cpufrequtils > /dev/null 2>&1
    echo 'GOVERNOR="powersave"' > /etc/default/cpufrequtils
    systemctl restart cpufrequtils 2>/dev/null
    echo -e "${GREEN}✓${NC} CPU governor set to powersave"

    # Disable unnecessary services
    for svc in snapd snapd.socket snapd.apparmor unattended-upgrades ModemManager udisks2; do
        if systemctl disable --now "$svc" 2>/dev/null; then
            echo -e "${GREEN}✓${NC} Disabled $svc"
        fi
    done

    # Add noatime to fstab
    sed -i '/LABEL=writable/s/defaults/defaults,noatime/' /etc/fstab
    echo -e "${GREEN}✓${NC} Added noatime to fstab"

    # Reduce swappiness
    echo 'vm.swappiness=10' > /etc/sysctl.d/99-swappiness.conf
    sysctl -p /etc/sysctl.d/99-swappiness.conf > /dev/null 2>&1
    echo -e "${GREEN}✓${NC} Swappiness set to 10"

    # CPU governor auto-switch based on charging state
    tee /usr/local/bin/powermon.sh > /dev/null << 'PWREOF'
#!/bin/bash
last_state=""
while true; do
    voltage=$(cat /sys/class/power_supply/battery/voltage_now 2>/dev/null || echo "0")
    if [ "$voltage" -gt 4100000 ]; then
        state="charging"
    else
        state="battery"
    fi

    if [ "$state" != "$last_state" ]; then
        if [ "$state" = "charging" ]; then
            for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
                echo "ondemand" > "$cpu" 2>/dev/null
            done
        else
            for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
                echo "powersave" > "$cpu" 2>/dev/null
            done
        fi
        last_state="$state"
    fi
    sleep 30
done
PWREOF
    chmod +x /usr/local/bin/powermon.sh

    tee /etc/systemd/system/powermon.service > /dev/null << 'SVCEOF'
[Unit]
Description=Power Monitor - auto switch CPU governor
After=multi-user.target

[Service]
ExecStart=/usr/local/bin/powermon.sh
Restart=always
User=root

[Install]
WantedBy=multi-user.target
SVCEOF

    systemctl daemon-reload
    systemctl enable --now powermon.service
    echo -e "${GREEN}✓${NC} CPU governor auto-switch enabled"

    echo -e "${GREEN}✓${NC} All power optimizations applied"
fi

echo ""
echo -e "${GREEN}=========================================="
echo " Setup Complete!"
echo "==========================================${NC}"
echo ""
echo "Next steps:"
echo "  1. Reboot: sudo reboot"
echo "  2. The display and keyboard should now work"
echo ""
echo "After reboot:"
echo "  - Battery: cat /sys/class/power_supply/battery/capacity"
echo "  - The power button is disabled (no accidental reboots)"
if [ "$POWER_TWEAKS" = true ]; then
    echo "  - CPU auto-switches between powersave/ondemand based on charging"
fi
echo ""
echo "For more info: https://github.com/mikeshoss/hackberrypi-ubuntu-server"
echo ""
