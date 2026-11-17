#!/bin/bash
# Full Zenfan self-test (after install).  Run with: sudo ./test_zenfan.sh
#  1. installed files, driver, service
#  2. CPU fan full speed on/off
#  3. GPU fan full speed on/off
#  4. auto-boost: temporarily sets the trigger BELOW the current CPU temp so it
#     fires at idle, then restores your settings
[ "$EUID" -eq 0 ] || { echo "Run with sudo"; exit 1; }

HELPER=/usr/local/libexec/zenfan-helper
CONF=/etc/zenfan/boost.conf
FAN=$(dirname "$(grep -l '^asus$' /sys/class/hwmon/hwmon*/name)")
CPUT=$(dirname "$(grep -l '^k10temp$' /sys/class/hwmon/hwmon*/name)")
PASS=0 FAIL=0
ok()   { echo "  PASS  $1"; PASS=$((PASS + 1)); }
bad()  { echo "  FAIL  $1"; FAIL=$((FAIL + 1)); }
rpm()  { cat "$FAN/fan$1_input"; }
temp() { echo $(( $(cat "$CPUT/temp1_input") / 1000 )); }
wait_rpm() {  # wait_rpm <fan 1|2> <above|below> <rpm> <max s>
    for _ in $(seq "$4"); do
        r=$(rpm "$1")
        { [ "$2" = above ] && [ "$r" -ge "$3" ]; } && return 0
        { [ "$2" = below ] && [ "$r" -le "$3" ]; } && return 0
        sleep 1
    done
    return 1
}

ORIG_CONF=$(cat $CONF 2>/dev/null)
restore() {
    [ -n "$ORIG_CONF" ] && echo "$ORIG_CONF" > $CONF
    $HELPER all off >/dev/null 2>&1
}
trap restore EXIT

echo "=== 1. Installation ==="
for f in /usr/local/bin/zenfan-gui $HELPER /usr/local/libexec/zenfan-boostd \
         /usr/share/applications/org.zenfan.Zenfan.desktop /usr/share/polkit-1/actions/org.zenfan.fan.policy; do
    [ -e "$f" ] && ok "$f" || bad "$f missing"
done
[ -e /proc/zenbook_gpufan ] && ok "GPU fan driver loaded" || bad "GPU fan driver NOT loaded"
dkms status 2>/dev/null | grep -q "zenbook-gpufan.*installed" && ok "DKMS: rebuilds on kernel update" || bad "DKMS entry missing"
systemctl is-active -q zenfan-boostd && ok "auto-boost service running" || bad "auto-boost service not running"
systemctl is-enabled -q zenfan-boostd && ok "auto-boost starts at boot" || bad "auto-boost not enabled at boot"
[ -n "$ORIG_CONF" ] && ok "settings: $(echo $ORIG_CONF)" || bad "no $CONF"

# keep auto-boost out of the way for tests 2-3
printf 'enabled=0\non=80\noff=65\n' > $CONF; sleep 3

echo "=== 2. CPU fan (now $(rpm 1) RPM, $(temp) °C) ==="
$HELPER cpu on && wait_rpm 1 above 5000 15 && ok "CPU full speed: $(rpm 1) RPM" || bad "CPU did not reach 5000 RPM ($(rpm 1))"
$HELPER cpu off && wait_rpm 1 below 4500 25 && ok "CPU back to auto: $(rpm 1) RPM" || bad "CPU did not slow down ($(rpm 1))"

echo "=== 3. GPU fan (now $(rpm 2) RPM) ==="
$HELPER gpu on && wait_rpm 2 above 5000 15 && ok "GPU full speed: $(rpm 2) RPM" || bad "GPU did not reach 5000 RPM ($(rpm 2))"
$HELPER gpu off && wait_rpm 2 below 4500 25 && ok "GPU back to auto: $(rpm 2) RPM" || bad "GPU did not slow down ($(rpm 2))"

echo "=== 4. Auto-boost (CPU is $(temp) °C) ==="
T=$(temp)
ON=$(( T - 5 < 41 ? 41 : T - 5 ))
if [ "$T" -lt 46 ]; then
    bad "CPU too cool ($T °C) to test boost at idle - run again when warmer"
else
    printf 'enabled=1\non=%d\noff=40\n' $ON > $CONF
    echo "  (temporary trigger: full speed at $ON °C)"
    if wait_rpm 1 above 5000 20 && wait_rpm 2 above 5000 10; then
        ok "boost fired: CPU $(rpm 1) / GPU $(rpm 2) RPM, state=$(cat /run/zenfan/boost)"
    else
        bad "boost did not fire (CPU $(rpm 1), GPU $(rpm 2), state=$(cat /run/zenfan/boost 2>/dev/null))"
    fi
    printf 'enabled=1\non=99\noff=%d\n' $(( T + 10 > 98 ? 98 : T + 10 )) > $CONF
    echo "  (temporary release: automatic below $(( T + 10 )) °C)"
    if wait_rpm 1 below 4500 25 && wait_rpm 2 below 4500 10; then
        ok "boost released: CPU $(rpm 1) / GPU $(rpm 2) RPM, state=$(cat /run/zenfan/boost)"
    else
        bad "boost did not release (CPU $(rpm 1), GPU $(rpm 2))"
    fi
fi

echo
echo "Your settings restored: $(echo $ORIG_CONF)"
echo "RESULT: $PASS passed, $FAIL failed"
