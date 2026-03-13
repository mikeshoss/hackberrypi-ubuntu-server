# Ubuntu Server on HackberryPi CM5

Get Ubuntu Server 24.04 LTS running on the HackberryPi CM5 (Q20/Q10/9900) with full display and keyboard support.

## The Problem

The HackberryPi CM5 uses a HyperPixel4 Square DPI display and a custom carrier board. Flashing Ubuntu Server to the NVMe and booting results in a black screen — the OS boots fine but can't drive the display. The keyboard (connected via USB HID) also needs a custom device tree overlay to work properly.

## What This Fixes

- Display output on the HackberryPi's 720x720 HyperPixel4 Square screen
- BlackBerry keyboard + trackpad support via the `hackberrypicm5` overlay
- GPIO pin conflicts between DPI display, SPI, I2C, and UART
- NVMe boot from the M.2 2242 slot
- Battery monitoring via the MAX17048 fuel gauge on I2C
- (Optional) Power optimizations for better battery life

## Prerequisites

- HackberryPi CM5 (Q20, Q10, or 9900 variant)
- Raspberry Pi CM5 **Lite** (no eMMC)
- M.2 2242 NVMe SSD installed
- Ubuntu Server 24.04 LTS flashed to the NVMe via Raspberry Pi Imager

## Install Methods

### Method 1: From Raspberry Pi OS (Recommended)

If you have Raspberry Pi OS running on the SD card, boot into it and run:

```bash
curl -fsSL https://raw.githubusercontent.com/mikeshoss/hackberrypi-ubuntu-server/main/install.sh | bash
```

Then shut down, remove the SD card, and power on.

### Method 2: From a Computer (No Raspberry Pi OS)

If you flashed Ubuntu Server to the NVMe directly from your computer (via USB-to-NVMe adapter or similar):

1. Flash Ubuntu Server 24.04 LTS to the NVMe using Raspberry Pi Imager
2. Boot the HackberryPi — the screen will be black but the OS is running
3. Find the device on your network and SSH in: `ssh username@hostname.local`
4. Run the post-install script:

```bash
curl -fsSL https://raw.githubusercontent.com/mikeshoss/hackberrypi-ubuntu-server/main/install-post-boot.sh | sudo bash
```

5. Reboot and the display and keyboard will be working

### Power Optimization (Optional)

Both install methods support an optional `--power` flag to enable battery life optimizations:

```bash
# Method 1 (from Raspberry Pi OS)
curl -fsSL https://raw.githubusercontent.com/mikeshoss/hackberrypi-ubuntu-server/main/install.sh | bash -s -- --power

# Method 2 (from SSH after first boot)
curl -fsSL https://raw.githubusercontent.com/mikeshoss/hackberrypi-ubuntu-server/main/install-post-boot.sh | sudo bash -s -- --power
```

Power optimizations include:
- CPU governor auto-switching (powersave on battery, ondemand when charging)
- Disabling unnecessary services (snapd, ModemManager, unattended-upgrades)
- Filesystem `noatime` to reduce NVMe writes
- Reduced swappiness (10 instead of 60)

## Manual Setup Guide

If you prefer to do things step by step, here's the full process.

### 1. Flash Ubuntu Server to NVMe

Use Raspberry Pi Imager on any computer. Select **Ubuntu Server 24.04.4 LTS (64-bit)**, choose the NVMe as the target. Configure your hostname, username, password, Wi-Fi, and SSH during setup.

### 2. Verify Boot Order

The default EEPROM boot order should be SD → NVMe → USB → Network (`0xf2461`). If booting from Raspberry Pi OS, verify with:

```bash
sudo rpi-eeprom-config
```

Ensure `PCIE_PROBE=1` is set in the EEPROM config:

```bash
sudo rpi-eeprom-config --edit
```

### 3. Install Required Overlays

The HackberryPi needs two custom overlays that aren't included in standard Ubuntu Server.

**Option A: Copy from Raspberry Pi OS SD card**

```bash
sudo mount /dev/nvme0n1p1 /mnt
sudo cp /boot/firmware/overlays/hackberrypicm5.dtbo /mnt/overlays/
sudo cp /boot/firmware/overlays/hyperpixel4.dtbo /mnt/overlays/
sudo umount /mnt
```

**Option B: Download from GitHub (if no SD card available)**

SSH into the running Ubuntu Server and run:

```bash
sudo wget -O /boot/firmware/overlays/hackberrypicm5.dtbo \
    https://raw.githubusercontent.com/mikeshoss/hackberrypi-ubuntu-server/main/overlays/hackberrypicm5.dtbo
sudo wget -O /boot/firmware/overlays/hyperpixel4.dtbo \
    https://raw.githubusercontent.com/mikeshoss/hackberrypi-ubuntu-server/main/overlays/hyperpixel4.dtbo
```

The `vc4-kms-dpi-hyperpixel4sq.dtbo` overlay is typically included in the Ubuntu kernel package already. Verify with:

```bash
ls /boot/firmware/overlays/ | grep hyperpixel4sq
```

If missing, download it from the [ZitaoTech HackberryPiCM5 repo](https://github.com/ZitaoTech/HackberryPiCM5/tree/main/Operating%20System).

### 4. Configure config.txt

Edit the boot config:

```bash
sudo nano /boot/firmware/config.txt
```

Replace the contents with the [config.txt](config.txt) from this repo. The critical settings are:

```ini
# Disable SPI, I2C, UART to free GPIO pins for DPI display
dtparam=i2c_arm=off
dtparam=spi=off
enable_uart=0

# Load overlays in correct order (display overlay MUST be last)
[all]
dtoverlay=vc4-kms-v3d
dtoverlay=hackberrypicm5
dtparam=pciex1
dtoverlay=vc4-kms-v3d
dtoverlay=vc4-kms-dpi-hyperpixel4sq
```

### 5. Set Up Battery Monitoring

The HackberryPi uses a MAX17048 fuel gauge on I2C bus 15:

```bash
sudo modprobe max17040_battery
echo "max17048 0x36" | sudo tee /sys/bus/i2c/devices/i2c-15/new_device
```

Verify:

```bash
cat /sys/class/power_supply/battery/capacity
cat /sys/class/power_supply/battery/voltage_now
```

To persist across reboots, create `/etc/rc.local`:

```bash
sudo tee /etc/rc.local > /dev/null << 'EOF'
#!/bin/bash
modprobe max17040_battery
echo "max17048 0x36" > /sys/bus/i2c/devices/i2c-15/new_device
exit 0
EOF
sudo chmod +x /etc/rc.local
```

### 6. Disable Power Button (Recommended)

The side power button triggers accidental reboots. To disable it:

Create a udev rule:

```bash
sudo tee /etc/udev/rules.d/99-power-button.rules > /dev/null << 'EOF'
ACTION=="remove", GOTO="power_button_end"
SUBSYSTEM=="input", ATTRS{name}=="pwr_button", ENV{SYSTEMD_IGNORE}="1"
LABEL="power_button_end"
EOF
```

Disable all power key handlers in logind:

```bash
sudo sed -i 's/#HandlePowerKey=poweroff/HandlePowerKey=ignore/' /etc/systemd/logind.conf
sudo sed -i 's/#HandlePowerKeyLongPress=ignore/HandlePowerKeyLongPress=ignore/' /etc/systemd/logind.conf
sudo sed -i 's/#HandleRebootKey=reboot/HandleRebootKey=ignore/' /etc/systemd/logind.conf
sudo sed -i 's/#HandleRebootKeyLongPress=poweroff/HandleRebootKeyLongPress=ignore/' /etc/systemd/logind.conf
sudo sed -i 's/#HandleSuspendKey=suspend/HandleSuspendKey=ignore/' /etc/systemd/logind.conf
sudo sed -i 's/#HandleSuspendKeyLongPress=suspend/HandleSuspendKeyLongPress=ignore/' /etc/systemd/logind.conf
sudo sed -i 's/#HandleHibernateKey=hibernate/HandleHibernateKey=ignore/' /etc/systemd/logind.conf
sudo sed -i 's/#HandleHibernateKeyLongPress=ignore/HandleHibernateKeyLongPress=ignore/' /etc/systemd/logind.conf
sudo sed -i 's/#HandleLidSwitch=suspend/HandleLidSwitch=ignore/' /etc/systemd/logind.conf
sudo sed -i 's/#HandleLidSwitchExternalPower=suspend/HandleLidSwitchExternalPower=ignore/' /etc/systemd/logind.conf
sudo sed -i 's/#HandleLidSwitchDocked=ignore/HandleLidSwitchDocked=ignore/' /etc/systemd/logind.conf
sudo systemctl restart systemd-logind
```

Reboot for the udev rule to take effect.

## Key Config Decisions Explained

### Why `dtparam=spi=off`?

The HyperPixel4 DPI display needs GPIO pins that overlap with the default SPI bus. Enabling SPI globally causes a pin conflict (`pin gpio7 already requested by spi; cannot claim for dpi`). The `hackberrypicm5` overlay handles any SPI the board needs internally.

### Why `dtparam=i2c_arm=off`?

The default I2C bus uses GPIO pins 2 and 3 which the DPI display also needs. The `hackberrypicm5` overlay sets up I2C on alternate pins (bus 13, 14, 15) for the battery monitor and RTC.

### Why `enable_uart=0`?

The default UART uses GPIO 14 which conflicts with DPI. Disabling it frees the pin for the display.

### Why is the overlay order important?

The `[all]` section at the bottom loads overlays in a specific order:
1. `vc4-kms-v3d` — KMS graphics driver
2. `hackberrypicm5` — HackberryPi carrier board setup (keyboard, pin routing)
3. `pciex1` — Enable PCIe for NVMe
4. `vc4-kms-v3d` — Reinitialize after overlay changes
5. `vc4-kms-dpi-hyperpixel4sq` — DPI display driver (must be last)

The DPI display claims GPIO pins 0-27. Loading it last ensures all other overlays have configured their alternate pin assignments first, avoiding conflicts.

### Charging Detection

The MAX17048 fuel gauge doesn't report charging status directly. Charging can be inferred from voltage: a LiPo cell above 4.1V is almost certainly on the charger. Below 4.1V it's on battery power.

## Power Optimizations

These are included when using the `--power` flag during install:

| Optimization | What it does | Impact |
|---|---|---|
| CPU governor auto-switch | `powersave` on battery, `ondemand` on charger | Biggest battery saver — 30-60 min extra |
| Disable snapd | Removes snap daemon and socket | Frees ~100MB RAM, reduces disk writes |
| Disable unattended-upgrades | No background apt updates | Reduces CPU/disk spikes |
| Disable ModemManager | Not needed without cellular modem | Small RAM savings |
| Filesystem noatime | Stops updating file access timestamps | Reduces NVMe writes significantly |
| Swappiness = 10 | Keeps more in RAM, less disk swapping | Less NVMe activity on battery |

## Hardware Tested

- HackberryPi CM5 Q20
- Raspberry Pi CM5 Lite (4GB / 8GB / 16GB)
- Corsair MP600 Micro (M.2 2242 NVMe)
- Ubuntu Server 24.04.4 LTS (64-bit)

## Troubleshooting

### Black screen but device is reachable via SSH

The display overlay isn't loading. Check `dmesg` for pin conflicts:

```bash
sudo dmesg | grep -i "pin.*claim\|dpi\|error.*apply"
```

Common culprits: SPI, I2C, or UART claiming GPIO pins before DPI. Ensure all three are disabled in the `dtparam` lines.

### Keyboard not working

The `hackberrypicm5.dtbo` overlay is missing. Copy it from a working Raspberry Pi OS installation or download from this repo's `overlays/` directory.

### NVMe not detected

Ensure `PCIE_PROBE=1` is set in the EEPROM config and `dtparam=pciex1` is in `config.txt`.

### Battery monitoring not working

The MAX17048 fuel gauge needs to be manually bound on each boot. Ensure `/etc/rc.local` is set up correctly and executable.

### Power button causes reboots

The udev rule and logind changes need a reboot to fully take effect. Ensure both the udev rule exists at `/etc/udev/rules.d/99-power-button.rules` and all `Handle*` lines in `/etc/systemd/logind.conf` are set to `ignore`.

## Credits

- [ZitaoTech](https://github.com/ZitaoTech/HackberryPiCM5) — HackberryPi CM5 creator
- [Carbon Computers](https://carboncomputers.us/) — HackberryPi CM5 distributor
- Display overlay files from the [HackberryPiCM5 Operating System repo](https://github.com/ZitaoTech/HackberryPiCM5/tree/main/Operating%20System)

## License

MIT
