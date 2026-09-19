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
# SYSTEM INFORMATION
# ================================================================

section "AIC8800D80 Wi-Fi + Bluetooth Installer v4"

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
# 1/12 PRE-INSTALL HARDWARE CHECK
# ================================================================

section "1/12 - PRE-INSTALL HARDWARE CHECK"

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
# 2/12 OPERATING SYSTEM CHECK
# ================================================================

section "2/12 - CHECKING OPERATING SYSTEM"

command -v apt-get >/dev/null 2>&1 ||
    fail "apt-get not found. Debian/Raspberry Pi OS is required."

command -v systemctl >/dev/null 2>&1 ||
    fail "systemd was not detected."

ok "apt and systemd detected."


# ================================================================
# 3/12 INSTALL PACKAGES
# ================================================================

section "3/12 - INSTALLING REQUIRED PACKAGES"

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
# 4/12 KERNEL HEADERS
# ================================================================

section "4/12 - CHECKING KERNEL HEADERS"

if [ -d "/lib/modules/$KERNEL/build" ]; then

    ok "Correct headers already installed for $KERNEL"

else

    warn "Headers for running kernel $KERNEL are missing."

    if apt-cache show "linux-headers-$KERNEL" >/dev/null 2>&1; then

        apt-get install -y "linux-headers-$KERNEL"

    else

        case "$ARCH" in

            armv7l)

                echo "Installing Raspberry Pi ARMv7 headers..."
                apt-get install -y linux-headers-rpi-v7
                ;;

            aarch64)

                echo "Installing Raspberry Pi ARM64 headers..."
                apt-get install -y linux-headers-rpi-v8 || true
                ;;

            *)

                fail "Unable to determine appropriate Raspberry Pi kernel headers."
                ;;

        esac

    fi
fi

if [ ! -d "/lib/modules/$KERNEL/build" ]; then
    fail "Headers matching running kernel $KERNEL are unavailable."
fi

ok "Kernel headers match running kernel."


# ================================================================
# 5/12 DRIVER SOURCE
# ================================================================

section "5/12 - CHECKING DRIVER SOURCE"

if [ -d "$SRC/.git" ]; then

    echo "Existing repository found: $SRC"
    echo "Updating repository..."

    git -C "$SRC" fetch --all --prune

    DEFAULT_BRANCH="$(
        git -C "$SRC" symbolic-ref \
        refs/remotes/origin/HEAD 2>/dev/null |
        sed 's@^refs/remotes/origin/@@' || true
    )"

    if [ -z "$DEFAULT_BRANCH" ]; then
        DEFAULT_BRANCH="main"
    fi

    git -C "$SRC" reset --hard "origin/$DEFAULT_BRANCH"

else

    if [ -e "$SRC" ]; then
        fail "$SRC exists but is not a Git repository."
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
# 6/12 DRIVER INSTALLATION
# ================================================================

section "6/12 - INSTALLING AIC8800 DKMS DRIVER"

chmod +x "$SRC/install.sh"

cd "$SRC"

INSTALL_RC=0

./install.sh --skip-deps || INSTALL_RC=$?

echo
echo "Upstream installer exit code: $INSTALL_RC"

depmod -a

echo
echo "--- DKMS verification ---"

DKMS_OUTPUT="$(dkms status 2>/dev/null || true)"

echo "$DKMS_OUTPUT"

if echo "$DKMS_OUTPUT" | grep -qi 'aic8800.*installed'; then
    ok "AIC8800 DKMS installation verified."
else
    fail "AIC8800 DKMS module is NOT installed."
fi

if modinfo aic8800_fdrv >/dev/null 2>&1; then
    ok "aic8800_fdrv module exists."
else
    fail "aic8800_fdrv module is missing."
fi

if modinfo aic_load_fw >/dev/null 2>&1; then
    ok "aic_load_fw module exists."
else
    fail "aic_load_fw module is missing."
fi

if [ "$INSTALL_RC" -ne 0 ]; then
    warn "Upstream installer returned exit code $INSTALL_RC."
    warn "DKMS and driver modules passed independent verification, so installation continues."
else
    ok "Upstream installer returned exit code 0."
fi


# ================================================================
# 7/12 PERSISTENT MODULES
# ================================================================

section "7/12 - CONFIGURING PERSISTENT MODULES"

cat > "$MODULES_FILE" <<'EOF'
sg
aic_load_fw
aic8800_fdrv
EOF

chmod 644 "$MODULES_FILE"

cat "$MODULES_FILE"

ok "Persistent module configuration installed."


# ================================================================
# 8/12 USB MODE SWITCH
# ================================================================

section "8/12 - CONFIGURING AUTOMATIC USB MODE SWITCH"

SG_RAW="$(command -v sg_raw || true)"

if [ -z "$SG_RAW" ]; then
    fail "sg_raw was not found."
fi

echo "sg_raw: $SG_RAW"

cat > "$UDEV_RULE" <<EOF
ACTION=="add", SUBSYSTEM=="scsi_generic", ATTRS{idVendor}=="1111", ATTRS{idProduct}=="1111", RUN+="$SG_RAW /dev/%k FD 00 00 00 00 00 00 00 00 00 00 00 00 00 00 F2"
EOF

chmod 644 "$UDEV_RULE"

udevadm control --reload-rules

echo
echo "Installed udev rule:"
cat "$UDEV_RULE"

ok "Automatic USB mode switch configured."


# ================================================================
# TRY CURRENT MODE SWITCH
# ================================================================

if lsusb | grep -qi '1111:1111'; then

    echo
    echo "Adapter currently in 1111:1111 storage mode."
    echo "Looking for its SCSI generic device..."

    modprobe sg || true
    sleep 2

    SG_DEVICE=""

    for DEV in /sys/class/scsi_generic/sg*; do

        [ -e "$DEV" ] || continue

        SG_NAME="$(basename "$DEV")"

        BLOCK_NAME="$(
            find "$DEV/device/block" \
            -mindepth 1 \
            -maxdepth 1 \
            -printf '%f\n' 2>/dev/null |
            head -n1 || true
        )"

        if [ -n "$BLOCK_NAME" ]; then

            if udevadm info \
                --query=property \
                --name="/dev/$BLOCK_NAME" 2>/dev/null |
                grep -q 'ID_VENDOR_ID=1111'; then

                SG_DEVICE="/dev/$SG_NAME"
                break
            fi
        fi
    done

    if [ -n "$SG_DEVICE" ]; then

        echo "AIC SCSI device: $SG_DEVICE"
        echo "Sending F2 mode-switch command..."

        "$SG_RAW" "$SG_DEVICE" \
            FD 00 00 00 00 00 00 00 \
            00 00 00 00 00 00 00 F2 || true

        sleep 5

    else

        warn "Unable to identify the AIC /dev/sg device automatically."
        warn "The persistent udev rule is still installed."
    fi
fi

echo
echo "--- USB state ---"
lsusb || true


# ================================================================
# 9/12 NETWORK + BLUETOOTH
# ================================================================

section "9/12 - CONFIGURING NETWORK AND BLUETOOTH"

systemctl enable NetworkManager.service
systemctl enable bluetooth.service

systemctl restart NetworkManager.service
systemctl restart bluetooth.service

rfkill unblock wifi 2>/dev/null || true
rfkill unblock bluetooth 2>/dev/null || true

nmcli radio wifi on 2>/dev/null || true

modprobe sg || true
modprobe aic_load_fw || true
modprobe aic8800_fdrv || true

sleep 5

echo
echo "--- Loaded modules ---"

lsmod | grep -E '^aic|cfg80211' || true

echo
echo "--- Current interfaces ---"

ip -br link || true


# ================================================================
# 10/12 INTERACTIVE WI-FI SETUP
# ================================================================

section "10/12 - WI-FI SETUP"

if ! ip link show wlan0 >/dev/null 2>&1; then

    warn "wlan0 does not exist."
    warn "Interactive Wi-Fi setup cannot continue."

else

    echo "Enabling Wi-Fi radio..."
    nmcli radio wifi on || true

    echo "Unblocking Wi-Fi..."
    rfkill unblock wifi || true

    sleep 3

    echo
    echo "Scanning for Wi-Fi networks..."

    nmcli device wifi rescan ifname wlan0 || true

    sleep 5

    echo
    echo "================================================"
    echo " AVAILABLE WI-FI NETWORKS"
    echo "================================================"
    echo

    nmcli -f IN-USE,SSID,SIGNAL,FREQ,SECURITY \
        device wifi list ifname wlan0 || true

    echo
    echo "================================================"
    echo " ENTER WI-FI DETAILS"
    echo "================================================"
    echo

    while true; do

        read -r -p "Wi-Fi name (SSID): " WIFI_SSID

        if [ -n "$WIFI_SSID" ]; then
            break
        fi

        echo "SSID cannot be empty."

    done

    echo

    while true; do

        read -r -s -p "Wi-Fi password: " WIFI_PASSWORD
        echo

        if [ -n "$WIFI_PASSWORD" ]; then
            break
        fi

        echo "Password cannot be empty."

    done

    echo
    echo "Connecting wlan0 to: $WIFI_SSID"
    echo

    WIFI_CONNECT_RC=0

    nmcli device wifi connect "$WIFI_SSID" \
        password "$WIFI_PASSWORD" \
        ifname wlan0 || WIFI_CONNECT_RC=$?

    unset WIFI_PASSWORD

    echo
    echo "================================================"
    echo " WI-FI CONNECTION RESULT"
    echo "================================================"

    if [ "$WIFI_CONNECT_RC" -eq 0 ]; then

        ok "NetworkManager accepted the Wi-Fi connection."

    else

        warn "NetworkManager returned error code $WIFI_CONNECT_RC."

    fi

    sleep 5


    # ============================================================
    # REQUESTED WI-FI VERIFICATION
    # ============================================================

    echo
    echo "================================================"
    echo " WI-FI VERIFICATION"
    echo "================================================"

    echo
    echo "--- nmcli device status ---"
    nmcli device status || true

    echo
    echo "--- ip -br addr show wlan0 ---"
    ip -br addr show wlan0 || true

    echo
    echo "--- iw dev wlan0 link ---"
    iw dev wlan0 link || true


    # ============================================================
    # AUTOMATIC RESULT CHECK
    # ============================================================

    echo
    echo "================================================"
    echo " WI-FI STATUS CHECK"
    echo "================================================"

    WIFI_OK=1

    if nmcli -t -f GENERAL.STATE \
        device show wlan0 2>/dev/null |
        grep -q '100'; then

        ok "wlan0 is connected."

    else

        warn "wlan0 is not reported as fully connected."
        WIFI_OK=0

    fi


    if ip -4 addr show wlan0 |
        grep -q 'inet '; then

        WIFI_IP="$(
            ip -4 -o addr show wlan0 |
            awk '{print $4}' |
            cut -d/ -f1 |
            head -n1
        )"

        ok "wlan0 IPv4 address: $WIFI_IP"

    else

        warn "wlan0 does not have an IPv4 address."
        WIFI_OK=0

    fi


    if iw dev wlan0 link 2>/dev/null |
        grep -q '^Connected to'; then

        ok "Wi-Fi association confirmed."

    else

        warn "Wi-Fi association not confirmed."
        WIFI_OK=0

    fi


    if [ "$WIFI_OK" -eq 1 ]; then

        echo
        echo "================================================"
        echo " WIFI CONNECTED SUCCESSFULLY"
        echo "================================================"

    else

        echo
        warn "Wi-Fi setup did not fully pass verification."
        warn "Installation will continue so diagnostics can be installed."

    fi

fi


# ================================================================
# 11/12 POST-BOOT CHECK
# ================================================================

section "11/12 - INSTALLING POST-BOOT CHECK"

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
echo "Waiting for AIC8800D80..."

FOUND=0

for i in $(seq 1 30); do

    if lsusb | grep -qi 'a69c:8d81'; then

        echo "[OK] AIC8800D80 operational: a69c:8d81"
        FOUND=1
        break

    fi

    if lsusb | grep -qi 'a69c:8d80'; then

        echo "AIC firmware-loader mode: a69c:8d80"

    elif lsusb | grep -qi '1111:1111'; then

        echo "AIC storage mode: 1111:1111"
        echo "Waiting for automatic mode switch..."

    else

        echo "Waiting for AIC USB adapter..."

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
echo " WLAN0 ADDRESS"
echo "================================================"

ip -br addr show wlan0 || true


echo
echo "================================================"
echo " WI-FI LINK"
echo "================================================"

iw dev wlan0 link || true


echo
echo "================================================"
echo " RFKILL"
echo "================================================"

rfkill list || true


echo
echo "================================================"
echo " BLUETOOTH"
echo "================================================"

bluetoothctl show || true


echo
echo "================================================"
echo " POST-BOOT RESULT"
echo "================================================"

if lsusb | grep -qi 'a69c:8d81'; then
    echo "[OK] USB: AIC8800D80 operational."
else
    echo "[WARNING] USB: a69c:8d81 not detected."
fi

if dkms status 2>/dev/null | grep -qi 'aic8800.*installed'; then
    echo "[OK] DKMS: driver installed."
else
    echo "[WARNING] DKMS: driver not reported installed."
fi

if lsmod | grep -q '^aic8800_fdrv'; then
    echo "[OK] DRIVER: aic8800_fdrv loaded."
else
    echo "[WARNING] DRIVER: aic8800_fdrv not loaded."
fi

if ip link show wlan0 >/dev/null 2>&1; then
    echo "[OK] WIFI: wlan0 exists."
else
    echo "[WARNING] WIFI: wlan0 missing."
fi

if nmcli -t -f GENERAL.STATE \
    device show wlan0 2>/dev/null |
    grep -q '100'; then

    echo "[OK] WIFI: wlan0 connected."
else
    echo "[WARNING] WIFI: wlan0 not connected."
fi

if ip -4 addr show wlan0 2>/dev/null |
    grep -q 'inet '; then

    WIFI_IP="$(
        ip -4 -o addr show wlan0 |
        awk '{print $4}' |
        cut -d/ -f1 |
        head -n1
    )"

    echo "[OK] WIFI IPv4: $WIFI_IP"

else

    echo "[WARNING] WIFI: no IPv4 address."

fi

if iw dev wlan0 link 2>/dev/null |
    grep -q '^Connected to'; then

    echo "[OK] WIFI: wireless association confirmed."

else

    echo "[WARNING] WIFI: wireless association not confirmed."

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

ok "Post-boot diagnostic script installed."


# ================================================================
# SYSTEMD SERVICE
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

if systemctl is-enabled --quiet aic8800-boot-check.service; then
    ok "aic8800-boot-check.service enabled."
else
    fail "Unable to enable aic8800-boot-check.service."
fi


# ================================================================
# 12/12 FINAL VALIDATION
# ================================================================

section "12/12 - FINAL PRE-REBOOT VALIDATION"


echo
echo "================================================"
echo " DKMS STATUS"
echo "================================================"

DKMS_FINAL="$(dkms status 2>/dev/null || true)"

echo "$DKMS_FINAL"

if echo "$DKMS_FINAL" | grep -qi 'aic8800.*installed'; then
    ok "DKMS persistence verified."
else
    fail "AIC8800 DKMS driver is not installed."
fi


echo
echo "================================================"
echo " DRIVER MODULES"
echo "================================================"

lsmod | grep -E '^aic|cfg80211' || true


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
echo " WLAN0 ADDRESS"
echo "================================================"

ip -br addr show wlan0 || true


echo
echo "================================================"
echo " WI-FI LINK"
echo "================================================"

iw dev wlan0 link || true


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
echo " RUNNING BOOT CHECK BEFORE REBOOT"
echo "================================================"

systemctl restart aic8800-boot-check.service || true


echo
echo "================================================"
echo " BOOT SERVICE STATUS"
echo "================================================"

systemctl status aic8800-boot-check.service --no-pager || true


# ================================================================
# PERSISTENCE VALIDATION
# ================================================================

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
    ok "$BOOT_SCRIPT installed."
else
    fail "$BOOT_SCRIPT missing."
fi

if systemctl is-enabled --quiet aic8800-boot-check.service; then
    ok "Boot-check service enabled."
else
    fail "Boot-check service disabled."
fi

if systemctl is-enabled --quiet NetworkManager.service; then
    ok "NetworkManager enabled."
else
    warn "NetworkManager not enabled."
fi

if systemctl is-enabled --quiet bluetooth.service; then
    ok "Bluetooth enabled."
else
    warn "Bluetooth service not enabled."
fi


# ================================================================
# FINAL CRITICAL CHECKS
# ================================================================

echo
echo "================================================"
echo " FINAL RESULT"
echo "================================================"

ERRORS=0

if dkms status 2>/dev/null | grep -qi 'aic8800.*installed'; then
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

if [ -f "$UDEV_RULE" ]; then
    echo "[OK] USB mode-switch rule installed."
else
    echo "[ERROR] USB mode-switch rule missing."
    ERRORS=$((ERRORS + 1))
fi

if systemctl is-enabled --quiet aic8800-boot-check.service; then
    echo "[OK] Boot-check service enabled."
else
    echo "[ERROR] Boot-check service disabled."
    ERRORS=$((ERRORS + 1))
fi


echo

if [ "$ERRORS" -eq 0 ]; then

    echo "================================================"
    echo " INSTALLATION SUCCESSFUL"
    echo "================================================"

    echo
    echo "Driver:                    OK"
    echo "DKMS persistence:          OK"
    echo "USB mode switch:           OK"
    echo "Module autoload:           OK"
    echo "Boot diagnostic service:   OK"
    echo "NetworkManager:             configured"
    echo "Bluetooth:                  configured"

else

    echo "================================================"
    echo " INSTALLATION HAS ERRORS"
    echo "================================================"

    echo
    echo "Critical errors: $ERRORS"
    echo "DO NOT reboot yet."

    exit 1
fi


echo
echo "================================================"
echo " LOG FILES"
echo "================================================"

echo
echo "Installer:"
echo "  /var/log/aic8800-installer.log"

echo
echo "Post-boot:"
echo "  /var/log/aic8800-boot.log"


echo
echo "================================================"
echo " AFTER REBOOT AUTOMATIC CHECKS"
echo "================================================"

echo
echo "The service automatically checks:"
echo
echo "  lsusb"
echo "  dkms status"
echo "  nmcli device status"
echo "  ip -br addr show wlan0"
echo "  iw dev wlan0 link"
echo "  rfkill list"
echo "  bluetoothctl show"


echo
echo "================================================"
echo " AFTER REBOOT MANUAL VERIFICATION"
echo "================================================"

echo
echo "Run:"
echo
echo "  sudo cat /var/log/aic8800-boot.log"
echo
echo "  nmcli device status"
echo "  ip -br addr show wlan0"
echo "  iw dev wlan0 link"
echo
echo "  bluetoothctl show"
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
