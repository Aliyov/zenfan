#!/bin/bash
# Simple fan control for ASUS Zenbook UX535QE
#   ./fan.sh               show fan speeds and modes
#   sudo ./fan.sh on       both fans full speed
#   sudo ./fan.sh off      both fans automatic
#   sudo ./fan.sh cpu on   / cpu off   only the CPU fan
#   sudo ./fan.sh gpu on   / gpu off   only the GPU fan
#
# CPU fan: asus_wmi pwm1_enable (0 = full, 2 = auto)
# GPU fan: zenbook_gpufan module, /proc/zenbook_gpufan (1 = full, 0 = auto)
#          (EC RAM 0x37 bit 0x40 - the BIOS's own GPU command hits the wrong byte)

for d in /sys/class/hwmon/hwmon*; do
    [ "$(cat "$d/name")" = "asus" ] && FAN="$d"
done
GPU=/proc/zenbook_gpufan

cpu() { echo "$1" > "$FAN/pwm1_enable"; }
gpu() {
    if [ -e "$GPU" ]; then echo "$1" > "$GPU"
    else echo "GPU fan: zenbook_gpufan module not loaded (see driver/)" >&2; fi
}

if [ "$1" = cpu ] || [ "$1" = gpu ]; then WHICH=$1; shift; else WHICH=all; fi

case "$1" in
    on)  [ $WHICH != gpu ] && cpu 0; [ $WHICH != cpu ] && gpu 1; echo "Fans ($WHICH): FULL SPEED" ;;
    off) [ $WHICH != gpu ] && cpu 2; [ $WHICH != cpu ] && gpu 0; echo "Fans ($WHICH): AUTO" ;;
    *)   cm=$([ "$(cat "$FAN/pwm1_enable")" = 0 ] && echo FULL || echo auto)
         gm=$([ -e "$GPU" ] && { [ "$(cat $GPU)" = 1 ] && echo FULL || echo auto; } || echo "n/a")
         echo "CPU fan: $(cat "$FAN/fan1_input") RPM  ($cm)"
         echo "GPU fan: $(cat "$FAN/fan2_input") RPM  ($gm)" ;;
esac
