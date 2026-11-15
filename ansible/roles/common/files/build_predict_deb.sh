#!/bin/bash
#
# Builds predict (KD2BD's satellite pass prediction) from its author's repository into
# /tmp/predict.deb, for stations where the bundled package can't be used (a 64-bit PC on
# Trixie or later: the bundled amd64 package needs ncurses 5). Run by Ansible (dependencies.yml).
#   build_predict_deb.sh COMMIT VERSION
set -e
commit=$1 version=$2
rm -rf /tmp/predict-src /tmp/predict-pkg /tmp/predict.deb
git init -q /tmp/predict-src
cd /tmp/predict-src
git remote add origin https://github.com/kd2bd/predict
git fetch -q --depth 1 origin "$commit"
git -c advice.detachedHead=false checkout -q FETCH_HEAD
# predict.h is normally written by predict's interactive installer
printf 'char *predictpath={"/usr/share/predict/"}, soundcard=0, *version={"2.2.5"};\n' > predict.h
cc -O2 predict.c -lm -lncurses -pthread -o predict 2>/dev/null
pkg=/tmp/predict-pkg
mkdir -p $pkg/DEBIAN $pkg/usr/bin $pkg/usr/share/doc/predict $pkg/usr/share/predict/default
install -m 0755 -s predict $pkg/usr/bin/predict
install -m 0644 COPYING CREDITS README.md $pkg/usr/share/doc/predict/
install -m 0644 default/* $pkg/usr/share/predict/default/ 2>/dev/null || true
cat > $pkg/DEBIAN/control <<CTL
Package: predict
Version: $version
Architecture: $(dpkg --print-architecture)
Maintainer: Raspberry-LRPT <raspberry-lrpt@localhost>
Depends: libc6, libncurses6, libtinfo6, netbase
Section: hamradio
Priority: optional
Homepage: https://github.com/kd2bd/predict
Description: Satellite tracking and orbital prediction (KD2BD)
 PREDICT 2.2.5 (${commit:0:7}), built from the author's repository by Raspberry-LRPT.
CTL
dpkg-deb --build --root-owner-group $pkg /tmp/predict.deb > /dev/null
rm -rf /tmp/predict-src /tmp/predict-pkg
