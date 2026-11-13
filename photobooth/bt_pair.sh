#!/bin/bash
# Pair the PS Move (plugged in over USB) with this machine's Bluetooth adapter.
# Run with: sudo bash bt_pair.sh
set -e
cd "$(dirname "$0")/psmoveapi/build"

# Newer BlueZ refuses unbonded HID devices like the Move unless this is off
cp -n /etc/bluetooth/input.conf /etc/bluetooth/input.conf.bak
sed -i 's/^#\?ClassicBondedOnly=.*/ClassicBondedOnly=false/' /etc/bluetooth/input.conf
grep -n ClassicBondedOnly /etc/bluetooth/input.conf

LD_LIBRARY_PATH=. ./psmove pair

systemctl restart bluetooth
echo "PAIR_DONE - unplug USB, then press the PS button"
