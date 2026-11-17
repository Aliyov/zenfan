#!/bin/bash
# Install Zenfan (app + GPU fan driver + auto-boost service):  sudo ./install.sh
# Uninstall everything:                                        sudo ./install.sh --uninstall
set -e
cd "$(dirname "$0")"
[ "$EUID" -eq 0 ] || { echo "Run with sudo"; exit 1; }

DRV=zenbook-gpufan
VER=1.0
BIN=/usr/local/bin/zenfan-gui
HELPER=/usr/local/libexec/zenfan-helper
BOOSTD=/usr/local/libexec/zenfan-boostd
UNIT=/etc/systemd/system/zenfan-boostd.service
POLICY=/usr/share/polkit-1/actions/org.zenfan.fan.policy
DESKTOP=/usr/share/applications/org.zenfan.Zenfan.desktop
ICON=/usr/share/icons/hicolor/scalable/apps/org.zenfan.Zenfan.svg
MODLOAD=/etc/modules-load.d/zenbook_gpufan.conf
CONF=/etc/zenfan/boost.conf

if [ "${1:-}" = "--uninstall" ]; then
    systemctl disable --now zenfan-boostd 2>/dev/null || true   # releases boosted fans
    rmmod zenbook_gpufan 2>/dev/null || true                     # GPU fan back to auto
    dkms remove -m $DRV -v $VER --all 2>/dev/null || true
    rm -rf "/usr/src/$DRV-$VER" /etc/zenfan /run/zenfan
    rm -f $BIN $HELPER $BOOSTD $UNIT $POLICY $DESKTOP $ICON $MODLOAD
    systemctl daemon-reload
    echo "Zenfan, auto-boost and the GPU fan driver removed."
else
    # --- checks + dependencies ---
    MODEL=$(cat /sys/class/dmi/id/product_name 2>/dev/null)
    case "$MODEL" in
        *UX535QE*) ;;
        *) echo "This is for the ASUS Zenbook UX535QE (found: '${MODEL:-unknown}'). Aborting."; exit 1 ;;
    esac
    command -v dnf >/dev/null || { echo "install.sh needs Fedora (dnf). See README for other distros."; exit 1; }
    dnf install -y dkms "kernel-devel-$(uname -r)" python3-gobject gtk4 libadwaita polkit
    if mokutil --sb-state 2>/dev/null | grep -q enabled; then
        echo "NOTE: Secure Boot is on. DKMS signs the module with /var/lib/dkms/mok.pub;"
        echo "      if the GPU driver does not load, enroll it once: sudo mokutil --import /var/lib/dkms/mok.pub (then reboot)."
    fi

    # --- GPU fan driver via DKMS (rebuilds on kernel updates) ---
    systemctl stop zenfan-boostd 2>/dev/null || true
    rmmod zenbook_gpufan 2>/dev/null || true
    dkms remove -m $DRV -v $VER --all 2>/dev/null || true
    rm -rf "/usr/src/$DRV-$VER"
    install -d "/usr/src/$DRV-$VER"
    install -m644 ../driver/zenbook_gpufan.c ../driver/Makefile ../driver/dkms.conf "/usr/src/$DRV-$VER/"
    dkms install -m $DRV -v $VER --force
    echo zenbook_gpufan > $MODLOAD
    modprobe zenbook_gpufan

    # --- app + service ---
    install -Dm755 zenfan-gui                $BIN
    install -Dm755 zenfan-helper             $HELPER
    install -Dm755 zenfan-boostd             $BOOSTD
    install -Dm644 zenfan-boostd.service     $UNIT
    install -Dm644 org.zenfan.fan.policy     $POLICY
    install -Dm644 org.zenfan.Zenfan.desktop $DESKTOP
    install -Dm644 zenfan.svg                $ICON
    [ -f $CONF ] || { install -d /etc/zenfan; printf 'enabled=1\non=80\noff=65\n' > $CONF; }
    chmod 644 $CONF
    restorecon -RF $BIN $HELPER $BOOSTD $UNIT $POLICY $DESKTOP $ICON $MODLOAD /etc/zenfan 2>/dev/null || true
    systemctl daemon-reload
    systemctl enable --now zenfan-boostd
    sleep 3
    echo
    echo "GPU fan driver : $([ -e /proc/zenbook_gpufan ] && echo loaded || echo NOT loaded)"
    echo "Auto-boost     : $(systemctl is-active zenfan-boostd) ($(cat /run/zenfan/boost 2>/dev/null); $(tr '\n' ' ' < $CONF))"
    echo "Find the app in Activities as 'Zenfan'."
fi
gtk-update-icon-cache -q /usr/share/icons/hicolor 2>/dev/null || true
update-desktop-database -q /usr/share/applications 2>/dev/null || true
