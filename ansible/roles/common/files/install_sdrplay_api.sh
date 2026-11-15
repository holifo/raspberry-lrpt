#!/bin/bash
#
# Installs SDRplay's API from its downloaded installer (/tmp/sdrplay_api.run) the way SDRplay's
# own install_lib.sh does, without its questions: library and headers in /usr/local, the
# sdrplay_apiService daemon and SDRplay's udev rules. Run by Ansible (sdrplay.yml) as root.
#   install_sdrplay_api.sh ARCH_DIR MAJOR.MINOR      e.g. arm64 3.15
set -e
arch=$1 mm=$2
rm -rf /tmp/sdrplay_api
sh /tmp/sdrplay_api.run --noexec --target /tmp/sdrplay_api > /dev/null
cd /tmp/sdrplay_api
install -m 0644 "$arch/libsdrplay_api.so.$mm" /usr/local/lib/
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
rm -rf /tmp/sdrplay_api /tmp/sdrplay_api.run
