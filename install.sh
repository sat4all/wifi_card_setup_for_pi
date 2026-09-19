#!/bin/bash
set -Eeuo pipefail

LOG="/var/log/aic8800-installer.log"
REPO="https://github.com/RicknotDev/aic8800d80.git"
SRC="/opt/aic8800d80"
BOOT_SCRIPT="/usr/local/sbin/aic8800-boot-check.sh"
SERVICE="/etc/systemd/system/aic8800-boot-check.service"
UDEV_RULE="/etc/udev/rules.d/99-aic8800-switch.rules"
MODULES_FILE="/etc/modules-load.d/aic8800.conf"

exec > >(tee -a "$LOG") 2>&1

trap 'echo; echo "ERROR: Installation failed at line $LINENO."; echo "Check: '"$LOG"'"; exit 1' ERR

section() {
    echo
    echo "================================================"
    echo " $1"
    echo "================================================"
}

ok() {
    echo "[OK] $1"
}

warn() {
    echo "[WARNING] $1"
}

fail() {
    echo "[ERROR] $1"
    exit 1
}

if [ "$EUID" -ne 0 ]; then
    fail "Run this script with sudo."
fi

section "AIC8800D80 Wi-Fi + Bluetooth Installer"

echo "Date:         $(date)"
echo "Hostname:     $(hostname)"
echo "Kernel:       $(uname -r)"
echo "Architecture: $(uname -m)"

if [ -r /proc/device-tree/model ]; then
    echo -n "Hardware:     "
    tr -d '\0' < /proc/device-tree/model
    echo
fi

if [ -f /etc/os-release ]; then
    . /etc/os-release
    echo "OS:           ${PRETTY_NAME:-unknown}"
fi

KERNEL="$(uname -r)"

section "1/11 - PRE-INSTALL HARDWARE CHECK"

echo "--- USB ---"
lsusb || true

USB_STORAGE=0
USB_AIC_LOAD=0
USB_AIC_READY=0

if lsusb | grep -qi '1111:1111'; then
    USB_STORAGE=1
    ok "AIC adapter detected in virtual-storage mode: 1111:1111"
fi

if lsusb | grep -qi 'a69c:8d80'; then
    USB_AIC_LOAD=1
    ok "AIC adapter detected in firmware-loader mode: a69c:8d80"
fi

if lsusb | grep -qi 'a69c:8d81'; then
    USB_AIC_READY=1
    ok "AIC8800D80 detected in operational mode: a69c:8d81"
fi

if [ "$USB_STORAGE" -eq 0 ] &&
   [ "$USB_AIC_LOAD" -eq 0 ] &&
   [ "$USB_AIC_READY" -eq 0 ]; then
    warn "Expected AIC USB IDs were not detected."
    warn "Installation can continue, but hardware cannot currently be verified."
fi

echo
echo "--- Existing network devices ---"
ip -br link || true

echo
echo "--- Existing RFKill state ---"
rfkill list 2>/dev/null || true

echo
echo "--- Existing AIC modules ---"
lsmod | grep -E '^aic|cfg80211' || true

echo
echo "--- Existing DKMS ---"
dkms status 2>/dev/null || true

section "2/11 - CHECKING OPERATING SYSTEM"

command -v apt-get >/dev/null 2>&1 ||
    fail "This installer requires an apt-based Debian/Raspberry Pi OS system."

command -v systemctl >/dev/null 2>&1 ||
    fail "systemd was not detected."

ok "apt and systemd detected."

section "3/11 - INSTALLING REQUIRED PACKAGES"

apt-get update

apt-get install -y \
    git \
    build-essential \
    dkms \
    bc \
    sg3-utils \
    usb-modeswitch \
    usb-modeswitch-data \
    network-manager \
    network-manager-gnome \
    bluez \
    blueman \
    rfkill \
    wireless-regdb \
    iw \
    usbutils

section "4/11 - CHECKING KERNEL HEADERS"

if [ -d "/lib/modules/$KERNEL/build" ]; then
    ok "Correct headers already installed for $KERNEL"
else
    warn "Headers for running kernel are missing."

    if apt-cache show "linux-headers-$KERNEL" >/dev/null 2>&1; then
        echo "Installing linux-headers-$KERNEL ..."
        apt-get install -y "linux-headers-$KERNEL"
    else
        echo "Exact header package not available."

        case "$(uname -m)" in
            armv7l)
                echo "Trying Raspberry Pi ARMv7 headers..."
                apt-get install -y linux-headers-rpi-v7
                ;;
            aarch64)
                echo "Trying Raspberry Pi ARM64 headers..."
                apt-get install -y linux-headers-rpi-2712 linux-headers-rpi-v8 2>/dev/null ||
                apt-get install -y linux-headers-rpi-v8
                ;;
            *)
                fail "Unable to determine an appropriate Raspberry Pi kernel-header package."
                ;;
        esac
    fi
fi

if [ ! -d "/lib/modules/$KERNEL/build" ]; then
    fail "Kernel headers matching $KERNEL are still unavailable. Driver build cannot safely continue."
fi

ok "Kernel headers match running kernel."

section "5/11 - DOWNLOADING DRIVER"

if [ -d "$SRC/.git" ]; then
    echo "Existing repository found."
    git -C "$SRC" fetch --all --prune
    git -C "$SRC" reset --hard origin/main
else
    if [ -e "$SRC" ]; then
        fail "$SRC exists but is not a Git repository. Not deleting it automatically."
    fi

    git clone "$REPO" "$SRC"
fi

test -f "$SRC/install.sh" ||
    fail "Driver install.sh not found."

test -f "$SRC/dkms.conf" ||
    fail "Driver dkms.conf not found."

echo
echo "Driver commit:"
git -C "$SRC" rev-parse HEAD

section "6/11 - INSTALLING AIC8800 DKMS DRIVER"

chmod +x "$SRC/install.sh"

cd "$SRC"

./install.sh --skip-deps

depmod -a

echo
echo "--- DKMS after installation ---"
dkms status

if ! dkms status | grep -qi 'aic8800.*installed'; then
    fail "AIC8800 DKMS entry is not reported as installed."
fi

ok "AIC8800 DKMS driver installed."

section "7/11 - CONFIGURING PERSISTENT MODULES"

cat > "$MODULES_FILE" <<'EOF'
sg
aic_load_fw
aic8800_fdrv
EOF

ok "Module autoload configuration installed."

section "8/11 - CONFIGURING AIC USB MODE SWITCH"

SG_RAW="$(command -v sg_raw || true)"

if [ -z "$SG_RAW" ]; then
    fail "sg_raw was not found after installing sg3-utils."
fi

cat > "$UDEV_RULE" <<EOF
ACTION=="add", SUBSYSTEM=="scsi_generic", ATTRS{idVendor}=="1111", ATTRS{idProduct}=="1111", RUN+="$SG_RAW /dev/%k FD 00 00 00 00 00 00 00 00 00 00 00 00 00 00 F2"
EOF

udevadm control --reload-rules

ok "Persistent 1111:1111 mode-switch rule installed."

section "9/11 - CONFIGURING NETWORK AND BLUETOOTH"

systemctl enable NetworkManager.service
systemctl enable bluetooth.service

systemctl restart NetworkManager.service
systemctl restart bluetooth.service

rfkill unblock wifi 2>/dev/null || true
rfkill unblock bluetooth 2>/dev/null || true

nmcli radio wifi on 2>/dev/null || true

modprobe sg

if modinfo aic_load_fw >/dev/null 2>&1; then
    modprobe aic_load_fw || true
else
    warn "aic_load_fw is not currently available to modprobe."
fi

if modinfo aic8800_fdrv >/dev/null 2>&1; then
    modprobe aic8800_fdrv || true
else
    warn "aic8800_fdrv is not currently available to modprobe."
fi

section "10/11 - INSTALLING POST-BOOT CHECK"

cat > "$BOOT_SCRIPT" <<'EOF'
#!/bin/bash

LOG="/var/log/aic8800-boot.log"

exec > >(tee "$LOG") 2>&1

echo "================================================"
echo " AIC8800D80 POST-BOOT CHECK"
echo "================================================"
echo "Date:   $(date)"
echo "Kernel: $(uname -r)"
echo

echo "Waiting for AIC USB device..."

FOUND=0

for i in $(seq 1 30); do

    if lsusb | grep -qi 'a69c:8d81'; then
        echo "[OK] AIC8800D80 operational device a69c:8d81 detected."
        FOUND=1
        break
    fi

    if lsusb | grep -qi 'a69c:8d80'; then
        echo "AIC firmware-loader device a69c:8d80 detected."
    elif lsusb | grep -qi '1111:1111'; then
        echo "AIC virtual-storage device 1111:1111 detected; waiting for mode switch..."
    fi

    sleep 2
done

echo
echo "Loading modules..."

modprobe sg 2>/dev/null || true
modprobe aic_load_fw 2>/dev/null || true
modprobe aic8800_fdrv 2>/dev/null || true

sleep 5

rfkill unblock wifi 2>/dev/null || true
rfkill unblock bluetooth 2>/dev/null || true

nmcli radio wifi on 2>/dev/null || true

sleep 5

echo
echo "================================================"
echo " lsusb"
echo "================================================"
lsusb

echo
echo "================================================"
echo " dkms status"
echo "================================================"
dkms status || true

echo
echo "================================================"
echo " AIC modules"
echo "================================================"
lsmod | grep -E '^aic|cfg80211' || true

echo
echo "================================================"
echo " nmcli device status"
echo "================================================"
nmcli device status || true

echo
echo "================================================"
echo " IP addresses"
echo "================================================"
ip -br addr || true

echo
echo "================================================"
echo " rfkill list"
echo "================================================"
rfkill list || true

echo
echo "================================================"
echo " bluetoothctl show"
echo "================================================"
bluetoothctl show || true

echo
echo "================================================"
echo " Wi-Fi"
echo "================================================"

if ip link show wlan0 >/dev/null 2>&1; then
    echo "[OK] wlan0 exists."
    iw dev wlan0 link || true
else
    echo "[WARNING] wlan0 not found."
fi

echo
echo "================================================"
echo " POST-BOOT CHECK COMPLETE"
echo "================================================"

if [ "$FOUND" -eq 0 ]; then
    echo "[WARNING] a69c:8d81 was not detected during the initial wait."
fi
EOF

chmod 755 "$BOOT_SCRIPT"

cat > "$SERVICE" <<'EOF'
[Unit]
Description=AIC8800D80 Wi-Fi and Bluetooth post-boot check
After=NetworkManager.service bluetooth.service
Wants=NetworkManager.service bluetooth.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/aic8800-boot-check.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable aic8800-boot-check.service

ok "Post-boot service installed and enabled."

section "11/11 - FINAL PRE-REBOOT VALIDATION"

echo "--- Driver files ---"

modinfo aic_load_fw 2>/dev/null | head -n 5 || true
echo
modinfo aic8800_fdrv 2>/dev/null | head -n 5 || true

echo
echo "================================================"
echo " DKMS STATUS"
echo "================================================"

dkms status

if dkms status | grep -qi 'aic8800.*installed'; then
    ok "DKMS persistence verified."
else
    fail "DKMS driver is not installed."
fi

echo
echo "================================================"
echo " STARTING BOOT CHECK NOW"
echo "================================================"

systemctl restart aic8800-boot-check.service || true

echo
echo "================================================"
echo " SYSTEMD SERVICE STATUS"
echo "================================================"

systemctl status aic8800-boot-check.service --no-pager || true

if systemctl is-enabled --quiet aic8800-boot-check.service; then
    ok "Boot-check service is enabled for future boots."
else
    fail "Boot-check service is NOT enabled."
fi

echo
echo "================================================"
echo " LSUSB"
echo "================================================"

lsusb

echo
echo "================================================"
echo " NMCLI DEVICE STATUS"
echo "================================================"

nmcli device status || true

echo
echo "================================================"
echo " RFKILL LIST"
echo "================================================"

rfkill list || true

echo
echo "================================================"
echo " BLUETOOTHCTL SHOW"
echo "================================================"

bluetoothctl show || true

echo
echo "================================================"
echo " MODULE STATUS"
echo "================================================"

lsmod | grep -E '^aic|cfg80211' || true

echo
echo "================================================"
echo " INSTALLATION FINISHED"
echo "================================================"

echo
echo "Installer log:"
echo "  $LOG"

echo
echo "Boot-check log:"
echo "  /var/log/aic8800-boot.log"

echo
echo "After reboot the following will run automatically:"
echo "  lsusb"
echo "  dkms status"
echo "  nmcli device status"
echo "  rfkill list"
echo "  bluetoothctl show"

echo
echo "The boot service is enabled:"
echo "  aic8800-boot-check.service"

echo
echo "Now reboot:"
echo
echo "  sudo reboot"
echo
echo "After reboot inspect:"
echo
echo "  sudo cat /var/log/aic8800-boot.log"
echo "  dkms status"
echo "  systemctl status aic8800-boot-check.service --no-pager"
