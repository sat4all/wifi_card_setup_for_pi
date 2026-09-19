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
    echo "Installer log: $LOG"
    exit 1
}

trap 'echo; echo "[ERROR] Script failed at line $LINENO."; echo "Check: '"$LOG"'"; exit 1' ERR


# ================================================================
# ROOT CHECK
# ================================================================

if [ "$EUID" -ne 0 ]; then
    echo "Run this script with:"
    echo
    echo "sudo ./wifiscript.sh"
    exit 1
fi


# ================================================================
# BASIC SYSTEM INFORMATION
# ================================================================

section "AIC8800D80 Wi-Fi + Bluetooth Installer"

KERNEL="$(uname -r)"
ARCH="$(uname -m)"

echo "Date:         $(date)"
echo "Hostname:     $(hostname)"
echo "Kernel:       $KERNEL"
echo "Architecture: $ARCH"

if [ -r /proc/device-tree/model ]; then
    echo -n "Hardware:     "
    tr -d '\0' < /proc/device-tree/model
    echo
fi

if [ -f /etc/os-release ]; then
    . /etc/os-release
    echo "OS:           ${PRETTY_NAME:-unknown}"
fi


# ================================================================
# 1. PRE-INSTALL HARDWARE CHECK
# ================================================================

section "1/11 - PRE-INSTALL HARDWARE CHECK"

echo "--- USB devices ---"
lsusb || true

echo

USB_STORAGE=0
USB_LOADER=0
USB_READY=0

if lsusb | grep -qi '1111:1111'; then
    USB_STORAGE=1
    ok "AIC adapter detected in virtual-storage mode: 1111:1111"
fi

if lsusb | grep -qi 'a69c:8d80'; then
    USB_LOADER=1
    ok "AIC adapter detected in firmware-loader mode: a69c:8d80"
fi

if lsusb | grep -qi 'a69c:8d81'; then
    USB_READY=1
    ok "AIC8800D80 detected in operational mode: a69c:8d81"
fi

if [ "$USB_STORAGE" -eq 0 ] &&
   [ "$USB_LOADER" -eq 0 ] &&
   [ "$USB_READY" -eq 0 ]; then

    warn "Expected AIC USB IDs were not detected."
    warn "Installation will continue, but hardware cannot currently be verified."

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


# ================================================================
# 2. OPERATING SYSTEM CHECK
# ================================================================

section "2/11 - CHECKING OPERATING SYSTEM"

command -v apt-get >/dev/null 2>&1 ||
    fail "apt-get not found. Debian/Raspberry Pi OS is required."

command -v systemctl >/dev/null 2>&1 ||
    fail "systemd was not detected."

ok "apt and systemd detected."


# ================================================================
# 3. REQUIRED PACKAGES
# ================================================================

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

ok "Required packages installed."


# ================================================================
# 4. KERNEL HEADERS
# ================================================================

section "4/11 - CHECKING KERNEL HEADERS"

if [ -d "/lib/modules/$KERNEL/build" ]; then

    ok "Correct headers already installed for $KERNEL"

else

    warn "Headers for running kernel $KERNEL are missing."

    if apt-cache show "linux-headers-$KERNEL" >/dev/null 2>&1; then

        echo "Installing exact kernel headers..."
        apt-get install -y "linux-headers-$KERNEL"

    else

        case "$ARCH" in

            armv7l)

                echo "ARMv7 Raspberry Pi detected."
                echo "Installing linux-headers-rpi-v7..."

                apt-get install -y linux-headers-rpi-v7
                ;;

            aarch64)

                echo "ARM64 Raspberry Pi detected."
                echo "Trying Raspberry Pi ARM64 headers..."

                apt-get install -y linux-headers-rpi-v8 || true
                ;;

            *)

                fail "Unable to determine correct Raspberry Pi kernel headers."

                ;;

        esac

    fi

fi


if [ ! -d "/lib/modules/$KERNEL/build" ]; then

    fail "Headers matching running kernel $KERNEL are unavailable."

fi

ok "Kernel headers match running kernel."


# ================================================================
# 5. DRIVER SOURCE
# ================================================================

section "5/11 - DOWNLOADING DRIVER"

if [ -d "$SRC/.git" ]; then

    echo "Existing driver repository found:"
    echo "$SRC"

    echo
    echo "Updating repository..."

    git -C "$SRC" fetch --all --prune

    DEFAULT_BRANCH="$(git -C "$SRC" symbolic-ref \
        refs/remotes/origin/HEAD 2>/dev/null |
        sed 's@^refs/remotes/origin/@@' || true)"

    if [ -z "$DEFAULT_BRANCH" ]; then
        DEFAULT_BRANCH="main"
    fi

    git -C "$SRC" reset --hard "origin/$DEFAULT_BRANCH"

else

    if [ -e "$SRC" ]; then

        fail "$SRC exists but is not a Git repository. It will NOT be deleted automatically."

    fi

    git clone "$REPO" "$SRC"

fi


if [ ! -f "$SRC/install.sh" ]; then
    fail "Driver install.sh was not found."
fi


if [ ! -f "$SRC/dkms.conf" ]; then
    fail "Driver dkms.conf was not found."
fi


echo
echo "Driver commit:"

git -C "$SRC" rev-parse HEAD

ok "Driver source verified."


# ================================================================
# 6. DKMS DRIVER INSTALLATION
# ================================================================

section "6/11 - INSTALLING AIC8800 DKMS DRIVER"

chmod +x "$SRC/install.sh"

cd "$SRC"

echo "Running upstream installer..."
echo

set +e

./install.sh --skip-deps

INSTALL_RC=$?

set -e


echo
echo "Upstream installer exit code: $INSTALL_RC"

echo
echo "Updating module dependencies..."

depmod -a


echo
echo "Checking DKMS..."

DKMS_OUTPUT="$(dkms status 2>/dev/null || true)"

echo "$DKMS_OUTPUT"


if echo "$DKMS_OUTPUT" |
    grep -qiE 'aic8800[/, ].*installed|aic8800.*installed'; then

    ok "AIC8800 DKMS installation verified."

else

    fail "AIC8800 DKMS module is NOT installed."

fi


echo
echo "Checking aic8800_fdrv..."

if modinfo aic8800_fdrv >/dev/null 2>&1; then

    ok "aic8800_fdrv module exists."

else

    fail "aic8800_fdrv module is missing."

fi


echo
echo "Checking aic_load_fw..."

if modinfo aic_load_fw >/dev/null 2>&1; then

    ok "aic_load_fw module exists."

else

    fail "aic_load_fw module is missing."

fi


# ================================================================
# 7. PERSISTENT MODULE LOADING
# ================================================================

section "7/11 - CONFIGURING PERSISTENT MODULES"

cat > "$MODULES_FILE" <<'EOF'
sg
aic_load_fw
aic8800_fdrv
EOF

chmod 644 "$MODULES_FILE"

echo "Created:"
echo "$MODULES_FILE"

cat "$MODULES_FILE"

ok "AIC modules configured for boot."


# ================================================================
# 8. USB MODE SWITCH
# ================================================================

section "8/11 - CONFIGURING AUTOMATIC USB MODE SWITCH"

SG_RAW="$(command -v sg_raw || true)"

if [ -z "$SG_RAW" ]; then

    fail "sg_raw was not found after installing sg3-utils."

fi

echo "sg_raw location:"
echo "$SG_RAW"


cat > "$UDEV_RULE" <<EOF
ACTION=="add", SUBSYSTEM=="scsi_generic", ATTRS{idVendor}=="1111", ATTRS{idProduct}=="1111", RUN+="$SG_RAW /dev/%k FD 00 00 00 00 00 00 00 00 00 00 00 00 00 00 F2"
EOF


chmod 644 "$UDEV_RULE"

udevadm control --reload-rules

echo
echo "Installed udev rule:"

cat "$UDEV_RULE"

ok "Automatic 1111:1111 mode switch configured."


# ================================================================
# 9. NETWORKMANAGER + BLUETOOTH
# ================================================================

section "9/11 - CONFIGURING NETWORK AND BLUETOOTH"

echo "Enabling NetworkManager..."

systemctl enable NetworkManager.service


echo
echo "Enabling Bluetooth..."

systemctl enable bluetooth.service


echo
echo "Restarting NetworkManager..."

systemctl restart NetworkManager.service


echo
echo "Restarting Bluetooth..."

systemctl restart bluetooth.service


echo
echo "Unblocking Wi-Fi..."

rfkill unblock wifi 2>/dev/null || true


echo
echo "Unblocking Bluetooth..."

rfkill unblock bluetooth 2>/dev/null || true


echo
echo "Enabling NetworkManager Wi-Fi radio..."

nmcli radio wifi on 2>/dev/null || true


echo
echo "Loading sg..."

modprobe sg


echo
echo "Loading AIC firmware module..."

modprobe aic_load_fw || true


echo
echo "Loading AIC Wi-Fi module..."

modprobe aic8800_fdrv || true


sleep 3


echo
echo "--- Loaded modules ---"

lsmod | grep -E '^aic|cfg80211' || true


# ================================================================
# 10. POST-BOOT DIAGNOSTIC SCRIPT
# ================================================================

section "10/11 - INSTALLING POST-BOOT CHECK"

cat > "$BOOT_SCRIPT" <<'BOOTEOF'
#!/bin/bash

LOG="/var/log/aic8800-boot.log"

exec > >(tee "$LOG") 2>&1

echo "================================================"
echo " AIC8800D80 POST-BOOT CHECK"
echo "================================================"

echo "Date:     $(date)"
echo "Hostname: $(hostname)"
echo "Kernel:   $(uname -r)"

echo
echo "Waiting for AIC USB adapter..."

FOUND=0


for i in $(seq 1 30); do

    if lsusb | grep -qi 'a69c:8d81'; then

        echo "[OK] AIC8800D80 operational device detected: a69c:8d81"

        FOUND=1

        break

    fi


    if lsusb | grep -qi 'a69c:8d80'; then

        echo "AIC firmware-loader device detected: a69c:8d80"

    elif lsusb | grep -qi '1111:1111'; then

        echo "AIC adapter is in virtual-storage mode: 1111:1111"
        echo "Waiting for automatic mode switch..."

    else

        echo "Waiting for AIC adapter..."

    fi

    sleep 2

done


echo
echo "Loading required modules..."

modprobe sg 2>/dev/null || true

modprobe aic_load_fw 2>/dev/null || true

modprobe aic8800_fdrv 2>/dev/null || true


sleep 5


echo
echo "Unblocking radios..."

rfkill unblock wifi 2>/dev/null || true

rfkill unblock bluetooth 2>/dev/null || true


echo
echo "Enabling Wi-Fi radio..."

nmcli radio wifi on 2>/dev/null || true


sleep 5


echo
echo "================================================"
echo " LSUSB"
echo "================================================"

lsusb


echo
echo "================================================"
echo " DKMS STATUS"
echo "================================================"

dkms status || true


echo
echo "================================================"
echo " AIC MODULES"
echo "================================================"

lsmod | grep -E '^aic|cfg80211' || true


echo
echo "================================================"
echo " NMCLI DEVICE STATUS"
echo "================================================"

nmcli device status || true


echo
echo "================================================"
echo " IP ADDRESSES"
echo "================================================"

ip -br addr || true


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
echo " WI-FI LINK"
echo "================================================"


if ip link show wlan0 >/dev/null 2>&1; then

    echo "[OK] wlan0 exists."

    iw dev wlan0 link || true

else

    echo "[WARNING] wlan0 was not found."

fi


echo
echo "================================================"
echo " FINAL HARDWARE RESULT"
echo "================================================"


if lsusb | grep -qi 'a69c:8d81'; then

    echo "[OK] USB: AIC8800D80 operational."

else

    echo "[WARNING] USB: a69c:8d81 not detected."

fi


if lsmod | grep -q '^aic8800_fdrv'; then

    echo "[OK] DRIVER: aic8800_fdrv loaded."

else

    echo "[WARNING] DRIVER: aic8800_fdrv not loaded."

fi


if ip link show wlan0 >/dev/null 2>&1; then

    echo "[OK] WIFI: wlan0 available."

else

    echo "[WARNING] WIFI: wlan0 unavailable."

fi


if bluetoothctl show >/dev/null 2>&1; then

    echo "[OK] BLUETOOTH: controller available."

else

    echo "[WARNING] BLUETOOTH: controller unavailable."

fi


if [ "$FOUND" -eq 0 ]; then

    echo "[WARNING] Adapter did not reach a69c:8d81 during initial wait."

fi


echo
echo "================================================"
echo " POST-BOOT CHECK COMPLETE"
echo "================================================"

BOOTEOF


chmod 755 "$BOOT_SCRIPT"

ok "Boot diagnostic script installed."


# ================================================================
# SYSTEMD BOOT SERVICE
# ================================================================

cat > "$SERVICE" <<'EOF'
[Unit]
Description=AIC8800D80 Wi-Fi and Bluetooth post-boot setup and check
After=NetworkManager.service bluetooth.service
Wants=NetworkManager.service bluetooth.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/aic8800-boot-check.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF


chmod 644 "$SERVICE"

systemctl daemon-reload

systemctl enable aic8800-boot-check.service

ok "aic8800-boot-check.service enabled."


# ================================================================
# 11. FINAL PRE-REBOOT VALIDATION
# ================================================================

section "11/11 - FINAL PRE-REBOOT VALIDATION"


echo
echo "================================================"
echo " DKMS STATUS"
echo "================================================"

DKMS_FINAL="$(dkms status 2>/dev/null || true)"

echo "$DKMS_FINAL"


if echo "$DKMS_FINAL" |
    grep -qiE 'aic8800[/, ].*installed|aic8800.*installed'; then

    ok "DKMS persistence verified."

else

    fail "DKMS AIC8800 driver is not installed."

fi


echo
echo "================================================"
echo " DRIVER MODULE INFORMATION"
echo "================================================"

echo
echo "--- aic_load_fw ---"

modinfo aic_load_fw |
    grep -E '^(filename|version|description):' || true


echo
echo "--- aic8800_fdrv ---"

modinfo aic8800_fdrv |
    grep -E '^(filename|version|description):' || true


echo
echo "================================================"
echo " LOADED MODULES"
echo "================================================"

lsmod | grep -E '^aic|cfg80211' || true


echo
echo "================================================"
echo " STARTING BOOT CHECK BEFORE REBOOT"
echo "================================================"

systemctl restart aic8800-boot-check.service || true


echo
echo "================================================"
echo " SYSTEMCTL STATUS"
echo "================================================"

systemctl status aic8800-boot-check.service --no-pager || true


echo
echo "Checking service enablement..."

if systemctl is-enabled --quiet aic8800-boot-check.service; then

    ok "aic8800-boot-check.service is enabled for boot."

else

    fail "aic8800-boot-check.service is NOT enabled."

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
echo " IP ADDRESSES"
echo "================================================"

ip -br addr || true


echo
echo "================================================"
echo " WI-FI LINK"
echo "================================================"

if ip link show wlan0 >/dev/null 2>&1; then

    iw dev wlan0 link || true

else

    warn "wlan0 is not currently available."

fi


echo
echo "================================================"
echo " PERSISTENCE CHECK"
echo "================================================"


if [ -f "$MODULES_FILE" ]; then

    ok "$MODULES_FILE exists."

else

    fail "$MODULES_FILE missing."

fi


if [ -f "$UDEV_RULE" ]; then

    ok "$UDEV_RULE exists."

else

    fail "$UDEV_RULE missing."

fi


if [ -x "$BOOT_SCRIPT" ]; then

    ok "$BOOT_SCRIPT installed and executable."

else

    fail "$BOOT_SCRIPT missing."

fi


if systemctl is-enabled --quiet NetworkManager.service; then

    ok "NetworkManager enabled."

else

    warn "NetworkManager not enabled."

fi


if systemctl is-enabled --quiet bluetooth.service; then

    ok "Bluetooth service enabled."

else

    warn "Bluetooth service not enabled."

fi


echo
echo "================================================"
echo " FINAL RESULT"
echo "================================================"


ERRORS=0


if echo "$DKMS_FINAL" |
    grep -qiE 'aic8800[/, ].*installed|aic8800.*installed'; then

    echo "[OK] DKMS driver installed."

else

    echo "[ERROR] DKMS driver missing."
    ERRORS=$((ERRORS + 1))

fi


if modinfo aic8800_fdrv >/dev/null 2>&1; then

    echo "[OK] aic8800_fdrv available."

else

    echo "[ERROR] aic8800_fdrv unavailable."
    ERRORS=$((ERRORS + 1))

fi


if modinfo aic_load_fw >/dev/null 2>&1; then

    echo "[OK] aic_load_fw available."

else

    echo "[ERROR] aic_load_fw unavailable."
    ERRORS=$((ERRORS + 1))

fi


if systemctl is-enabled --quiet aic8800-boot-check.service; then

    echo "[OK] Boot-check service enabled."

else

    echo "[ERROR] Boot-check service disabled."
    ERRORS=$((ERRORS + 1))

fi


if [ "$ERRORS" -eq 0 ]; then

    echo
    echo "================================================"
    echo " INSTALLATION SUCCESSFUL"
    echo "================================================"

    echo
    echo "Driver persistence:        OK"
    echo "DKMS:                      OK"
    echo "USB mode-switch rule:      OK"
    echo "Boot diagnostic service:   OK"
    echo "NetworkManager:             configured"
    echo "Bluetooth:                  configured"

else

    echo
    echo "================================================"
    echo " INSTALLATION HAS ERRORS"
    echo "================================================"

    echo
    echo "Do NOT reboot until the errors above are checked."

    exit 1

fi


echo
echo "Installer log:"
echo "  /var/log/aic8800-installer.log"

echo
echo "Boot diagnostic log:"
echo "  /var/log/aic8800-boot.log"


echo
echo "================================================"
echo " AFTER REBOOT"
echo "================================================"

echo
echo "The boot service will automatically run:"
echo
echo "  lsusb"
echo "  dkms status"
echo "  nmcli device status"
echo "  rfkill list"
echo "  bluetoothctl show"
echo "  iw dev wlan0 link"


echo
echo "After reboot check:"
echo
echo "  sudo cat /var/log/aic8800-boot.log"
echo
echo "  dkms status"
echo
echo "  systemctl status aic8800-boot-check.service --no-pager"


echo
echo "================================================"
echo " READY TO REBOOT"
echo "================================================"

echo
echo "Run:"
echo
echo "  sudo reboot"
echo
