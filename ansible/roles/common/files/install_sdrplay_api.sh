#!/bin/bash
#
# Installs SDRplay's API from its downloaded installer (/tmp/sdrplay_api.run) the way SDRplay's
# own install_lib.sh does, without its questions: library and headers in /usr/local, the
# sdrplay_apiService daemon and SDRplay's udev rules. Run by Ansible (sdrplay.yml) as root.
#   install_sdrplay_api.sh ARCH_DIR MAJOR.MINOR      e.g. arm64 3.15
set -e
arch=$1 mm=$2
work=/tmp/sdrplay_api
log=/tmp/sdrplay_api.log
rm -rf "$work" && mkdir -p "$work" && cd "$work"
# The installer is a makeself archive. "--tar xf" unpacks it into the current folder (what the
# Arch Linux package does for 3.15.2); "--noexec --target" is the other makeself way. Neither
# runs SDRplay's own interactive install script.
if ! sh /tmp/sdrplay_api.run --tar xf > "$log" 2>&1 || [ ! -d inc ]; then
  rm -rf "$work"
  sh /tmp/sdrplay_api.run --noexec --target "$work" >> "$log" 2>&1 || true
  cd "$work" 2>/dev/null || true
fi
lib=$(find "$work" -path "*/$arch/libsdrplay_api.so.$mm*" -type f 2>/dev/null | head -1)
if [ -z "$lib" ]; then
  echo "Could not unpack SDRplay's installer (no $arch/libsdrplay_api.so.$mm in it). Its output:"
  cat "$log"
  echo "Unpacked files:"; find "$work" -maxdepth 2 2>/dev/null | head -40
  exit 1
fi
cd "$(dirname "$(dirname "$lib")")"
install -m 0644 "$lib" "/usr/local/lib/libsdrplay_api.so.$mm"
ln -sf "libsdrplay_api.so.$mm" /usr/local/lib/libsdrplay_api.so.3
ln -sf libsdrplay_api.so.3 /usr/local/lib/libsdrplay_api.so
install -m 0755 "$arch/sdrplay_apiService" /usr/local/bin/sdrplay_apiService
install -m 0644 inc/*.h /usr/local/include/
# SDRplay's udev rules are written by its install_lib.sh; take them from there
awk 'index($0, "cat > /etc/udev/rules.d/66-sdrplay.rules") { f = 1; next } /^EOF/ { f = 0 } f' \
  install_lib.sh > /etc/udev/rules.d/66-sdrplay.rules
if [ ! -s /etc/udev/rules.d/66-sdrplay.rules ]; then
  echo 'SUBSYSTEM=="usb", ATTRS{idVendor}=="1df7", MODE="0666"' > /etc/udev/rules.d/66-sdrplay.rules
fi
mkdir -p /usr/local/share/doc/sdrplay_api
cp -f sdrplay_license.txt /usr/local/share/doc/sdrplay_api/ 2>/dev/null || true
ldconfig
cd /
rm -rf "$work" /tmp/sdrplay_api.run "$log"
