#!/bin/bash
# Zenfan installer for ASUS Zenbook UX535QE (Fedora).
#   sudo ./install.sh              install / update
#   sudo ./install.sh --uninstall  remove everything
exec "$(dirname "$(readlink -f "$0")")/app/install.sh" "$@"
