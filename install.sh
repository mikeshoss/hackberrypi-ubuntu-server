#!/bin/bash
# =============================================================================
# HackberryPi CM5 - Ubuntu Server Installer (Method 1: From Raspberry Pi OS)
# =============================================================================
# Run this from Raspberry Pi OS (SD card) after flashing Ubuntu Server to NVMe.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/mikeshoss/hackberrypi-ubuntu-server/main/install.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/mikeshoss/hackberrypi-ubuntu-server/main/install.sh | bash -s -- --power
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
echo " Method 1: From Raspberry Pi OS"
echo "=========================================="
if [ "$POWER_TWEAKS" = true ]; then
    echo -e " ${GREEN}Power optimizations: ENABLED${NC}"
fi
echo ""

# --- Check we're running on Raspberry Pi OS ---
if [ ! -f /boot/firmware/config.txt ]; then
    echo -e "${RED}Error: /boot/firmware/config.txt not found.${NC}"
    echo "This script must be run from Raspberry Pi OS (SD card)."
    echo "If you're already booted into Ubuntu Server, use install-post-boot.sh instead."
    exit 1
fi

# --- Check NVMe is detected ---
if [ ! -b /dev/nvme0n1 ]; then
    echo -e "${RED}Error: NVMe drive not detected at /dev/nvme0n1.${NC}"
    echo "Ensure your M.2 2242 NVMe SSD is installed and detected."
    echo "Try: lsblk"
    exit 1
fi

# --- Check NVMe has partitions (Ubuntu flashed) ---
if [ ! -b /dev/nvme0n1p1 ]; then
    echo -e "${RED}Error: No partitions found on NVMe.${NC}"
    echo "Flash Ubuntu Server 24.04 LTS to the NVMe first using Raspberry Pi Imager."
    exit 1
fi

echo -e "${GREEN}✓${NC} NVMe detected with partitions"

# --- Mount NVMe boot partition ---
echo ""
echo "Mounting NVMe boot partition..."
sudo mkdir -p /mnt/nvme-boot
sudo mount /dev/nvme0n1p1 /mnt/nvme-boot

# --- Verify it's a Ubuntu boot partition ---
if [ ! -f /mnt/nvme-boot/vmlinuz ]; then
    echo -e "${RED}Error: This doesn't look like a Ubuntu Server boot partition.${NC}"
    echo "Expected to find vmlinuz in the boot partition."
    sudo umount /mnt/nvme-boot
    exit 1
fi

echo -e "${GREEN}✓${NC} Ubuntu Server boot partition found"

# --- Copy hackberrypicm5 overlay ---
echo ""
echo "Copying HackberryPi overlays..."

if [ -f /boot/firmware/overlays/hackberrypicm5.dtbo ]; then
    sudo cp /boot/firmware/overlays/hackberrypicm5.dtbo /mnt/nvme-boot/overlays/
    echo -e "${GREEN}✓${NC} hackberrypicm5.dtbo copied"
else
    echo -e "${RED}Error: hackberrypicm5.dtbo not found on SD card.${NC}"
    echo "Your Raspberry Pi OS installation may be missing this overlay."
    echo "Download it from: https://github.com/ZitaoTech/HackberryPiCM5/tree/main/Operating%20System"
    sudo umount /mnt/nvme-boot
    exit 1
fi

# --- Copy HyperPixel display overlays ---
if [ -f /boot/firmware/overlays/vc4-kms-dpi-hyperpixel4sq.dtbo ]; then
    sudo cp /boot/firmware/overlays/vc4-kms-dpi-hyperpixel4sq.dtbo /mnt/nvme-boot/overlays/
    echo -e "${GREEN}✓${NC} vc4-kms-dpi-hyperpixel4sq.dtbo copied"
else
    if [ -f /mnt/nvme-boot/overlays/vc4-kms-dpi-hyperpixel4sq.dtbo ]; then
        echo -e "${GREEN}✓${NC} vc4-kms-dpi-hyperpixel4sq.dtbo already present on NVMe"
    else
        echo -e "${YELLOW}!${NC} Downloading vc4-kms-dpi-hyperpixel4sq.dtbo..."
        sudo wget -q -O /mnt/nvme-boot/overlays/vc4-kms-dpi-hyperpixel4sq.dtbo \
            https://raw.githubusercontent.com/ZitaoTech/HackberryPiCM5/main/Operating%20System/vc4-kms-dpi-hyperpixel4sq.dtbo
        echo -e "${GREEN}✓${NC} Downloaded vc4-kms-dpi-hyperpixel4sq.dtbo"
    fi
fi

if [ -f /boot/firmware/overlays/hyperpixel4.dtbo ]; then
    sudo cp /boot/firmware/overlays/hyperpixel4.dtbo /mnt/nvme-boot/overlays/
    echo -e "${GREEN}✓${NC} hyperpixel4.dtbo copied"
else
    if [ -f /mnt/nvme-boot/overlays/hyperpixel4.dtbo ]; then
        echo -e "${GREEN}✓${NC} hyperpixel4.dtbo already present on NVMe"
    else
        echo -e "${YELLOW}!${NC} Downloading hyperpixel4.dtbo..."
        sudo wget -q -O /mnt/nvme-boot/overlays/hyperpixel4.dtbo \
            https://raw.githubusercontent.com/ZitaoTech/HackberryPiCM5/main/Operating%20System/hyperpixel4.dtbo
        echo -e "${GREEN}✓${NC} Downloaded hyperpixel4.dtbo"
    fi
fi

# --- Write config.txt ---
echo ""
echo "Writing config.txt..."

sudo tee /mnt/nvme-boot/config.txt > /dev/null << 'CONFIGEOF'
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

# --- Unmount boot partition ---
sudo umount /mnt/nvme-boot

# --- Set up battery monitoring and power button on root partition ---
echo ""
echo "Configuring Ubuntu Server root partition..."

sudo mkdir -p /mnt/nvme-root
sudo mount /dev/nvme0n1p2 /mnt/nvme-root

# Battery monitoring via rc.local
sudo tee /mnt/nvme-root/etc/rc.local > /dev/null << 'RCEOF'
#!/bin/bash
modprobe max17040_battery
echo "max17048 0x36" > /sys/bus/i2c/devices/i2c-15/new_device
exit 0
RCEOF
sudo chmod +x /mnt/nvme-root/etc/rc.local
echo -e "${GREEN}✓${NC} Battery monitoring configured"

# Power button udev rule
sudo mkdir -p /mnt/nvme-root/etc/udev/rules.d
sudo tee /mnt/nvme-root/etc/udev/rules.d/99-power-button.rules > /dev/null << 'UDEVEOF'
ACTION=="remove", GOTO="power_button_end"
SUBSYSTEM=="input", ATTRS{name}=="pwr_button", ENV{SYSTEMD_IGNORE}="1"
LABEL="power_button_end"
UDEVEOF
echo -e "${GREEN}✓${NC} Power button udev rule configured"

# Disable power button in logind
sudo sed -i 's/#HandlePowerKey=poweroff/HandlePowerKey=ignore/' /mnt/nvme-root/etc/systemd/logind.conf
sudo sed -i 's/#HandlePowerKeyLongPress=ignore/HandlePowerKeyLongPress=ignore/' /mnt/nvme-root/etc/systemd/logind.conf
sudo sed -i 's/#HandleRebootKey=reboot/HandleRebootKey=ignore/' /mnt/nvme-root/etc/systemd/logind.conf
sudo sed -i 's/#HandleRebootKeyLongPress=poweroff/HandleRebootKeyLongPress=ignore/' /mnt/nvme-root/etc/systemd/logind.conf
sudo sed -i 's/#HandleSuspendKey=suspend/HandleSuspendKey=ignore/' /mnt/nvme-root/etc/systemd/logind.conf
sudo sed -i 's/#HandleSuspendKeyLongPress=suspend/HandleSuspendKeyLongPress=ignore/' /mnt/nvme-root/etc/systemd/logind.conf
sudo sed -i 's/#HandleHibernateKey=hibernate/HandleHibernateKey=ignore/' /mnt/nvme-root/etc/systemd/logind.conf
sudo sed -i 's/#HandleHibernateKeyLongPress=ignore/HandleHibernateKeyLongPress=ignore/' /mnt/nvme-root/etc/systemd/logind.conf
sudo sed -i 's/#HandleLidSwitch=suspend/HandleLidSwitch=ignore/' /mnt/nvme-root/etc/systemd/logind.conf
sudo sed -i 's/#HandleLidSwitchExternalPower=suspend/HandleLidSwitchExternalPower=ignore/' /mnt/nvme-root/etc/systemd/logind.conf
sudo sed -i 's/#HandleLidSwitchDocked=ignore/HandleLidSwitchDocked=ignore/' /mnt/nvme-root/etc/systemd/logind.conf
echo -e "${GREEN}✓${NC} Power button handlers disabled"

# --- Power optimizations (optional) ---
if [ "$POWER_TWEAKS" = true ]; then
    echo ""
    echo "Applying power optimizations..."

    # Disable unnecessary services
    for svc in snapd snapd.socket snapd.apparmor unattended-upgrades ModemManager udisks2; do
        if sudo chroot /mnt/nvme-root systemctl disable "$svc" 2>/dev/null; then
            echo -e "${GREEN}✓${NC} Disabled $svc"
        fi
    done

    # Add noatime to fstab
    sudo sed -i 's/defaults/defaults,noatime/' /mnt/nvme-root/etc/fstab
    echo -e "${GREEN}✓${NC} Added noatime to fstab"

    # Reduce swappiness
    echo 'vm.swappiness=10' | sudo tee /mnt/nvme-root/etc/sysctl.d/99-swappiness.conf > /dev/null
    echo -e "${GREEN}✓${NC} Swappiness set to 10"

    # CPU governor auto-switch service
    sudo tee /mnt/nvme-root/usr/local/bin/powermon.sh > /dev/null << 'PWREOF'
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
    sudo chmod +x /mnt/nvme-root/usr/local/bin/powermon.sh

    sudo tee /mnt/nvme-root/etc/systemd/system/powermon.service > /dev/null << 'SVCEOF'
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

    sudo chroot /mnt/nvme-root systemctl enable powermon.service 2>/dev/null
    echo -e "${GREEN}✓${NC} CPU governor auto-switch enabled"

    # Install cpufrequtils on first boot
    sudo tee /mnt/nvme-root/etc/rc.local > /dev/null << 'RCEOF'
#!/bin/bash
# Battery monitoring
modprobe max17040_battery
echo "max17048 0x36" > /sys/bus/i2c/devices/i2c-15/new_device

# Install cpufrequtils if not present
if ! command -v cpufreq-info &>/dev/null; then
    apt-get install -y cpufrequtils
    echo 'GOVERNOR="powersave"' > /etc/default/cpufrequtils
fi

exit 0
RCEOF
    sudo chmod +x /mnt/nvme-root/etc/rc.local
    echo -e "${GREEN}✓${NC} Power optimizations configured"
fi

# --- Unmount ---
echo ""
sudo umount /mnt/nvme-root

echo ""
echo -e "${GREEN}=========================================="
echo " Setup Complete!"
echo "==========================================${NC}"
echo ""
echo "Next steps:"
echo "  1. Shut down:  sudo shutdown now"
echo "  2. Remove the SD card"
echo "  3. Power on — Ubuntu Server should boot with display and keyboard"
echo ""
echo "After first boot:"
echo "  - Battery: cat /sys/class/power_supply/battery/capacity"
echo "  - The power button is disabled (no accidental reboots)"
if [ "$POWER_TWEAKS" = true ]; then
    echo "  - CPU auto-switches between powersave/ondemand based on charging"
fi
echo ""
echo "For more info: https://github.com/mikeshoss/hackberrypi-ubuntu-server"
echo ""
