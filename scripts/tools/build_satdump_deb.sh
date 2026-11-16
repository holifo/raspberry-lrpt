#!/bin/bash
#
# Builds the SatDump package the station installs, for this Pi's Debian release, when software/
# has none for it (today: Trixie). It builds the same SatDump commit as the Bookworm packages
# (satdump_commit in ansible/group_vars/all.yml), the way SatDump's own CI does (cmake, make,
# make package), and writes software/satdump_<version>_<codename>_<arch>.deb.
#
#   ~/raspberry-lrpt/scripts/tools/build_satdump_deb.sh [-j JOBS]
#
# About an hour on a Raspberry Pi 4 or 5, and about 4 GB of free disk. With less than 4 GB of
# RAM it builds with 2 jobs; add swap if the compiler is killed. It first builds and installs
# the RTL-SDR Blog driver packages (the same ones the install uses), so SatDump is built against
# them. Run ./install_and_upgrade.sh when it has finished.

set -e
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
JOBS=""
[ "$1" == "-j" ] && JOBS=$2

say()  { echo; echo "==> $*"; }
die()  { echo "xx  $*" >&2; exit 1; }

[ $EUID -eq 0 ] && die "Run it as your normal user, not with sudo"
codename=$(. /etc/os-release && echo "${DEBIAN_CODENAME:-$VERSION_CODENAME}")  # Debian-based (LMDE "gigi" = trixie)
arch=$(dpkg --print-architecture)
read -r satdump_version satdump_commit rtl_commit < <(python3 - "$REPO/ansible/group_vars/all.yml" <<'PY'
import re, sys
s = open(sys.argv[1]).read()
get = lambda k: re.search(r'^%s:\s*"([^"]+)"' % k, s, re.M).group(1)
print(get('satdump_version'), get('satdump_commit'), get('rtlsdr_blog_commit'))
PY
)
rtl_version="1:0.7.0~rtlsdrblog1+git${rtl_commit:0:7}"
out="$REPO/software/satdump_${satdump_version}_${codename}_${arch}.deb"
[ -f "$out" ] && die "$out already exists"

mem_mb=$(awk '/MemTotal/ {print int($2 / 1024)}' /proc/meminfo)
[ -n "$JOBS" ] || JOBS=$(( mem_mb >= 7000 ? $(nproc) : 2 ))
# the build needs about 4 GB; /tmp is often a small RAM disk (Trixie), so fall back to the home disk
base="${TMPDIR:-/tmp}"
free_mb=$(df -Pm "$base" | awk 'NR==2 {print $4}')
if [ "$free_mb" -le 4000 ] && [ -z "$TMPDIR" ]; then
  base="$HOME/.cache"; mkdir -p "$base"
  free_mb=$(df -Pm "$base" | awk 'NR==2 {print $4}')
fi
[ "$free_mb" -gt 4000 ] || die "Only ${free_mb} MB free in ${base}; the build needs about 4 GB (set TMPDIR to a bigger disk)"
WORK="$base/satdump-build"
echo "SatDump ${satdump_version} (${satdump_commit:0:9}) for ${codename} ${arch}, ${JOBS} jobs, ${mem_mb} MB RAM"

say "Build tools and libraries"
volk=libvolk-dev; [ "$codename" == "bookworm" ] && volk=libvolk2-dev
sudo apt-get update -qq
sudo apt-get install -y -q git build-essential cmake g++ pkgconf debhelper dpkg-dev fakeroot \
  libfftw3-dev libpng-dev libtiff-dev libjpeg-dev libjemalloc-dev libcurl4-openssl-dev "$volk" \
  libnng-dev libglfw3-dev zenity portaudio19-dev libzstd-dev libhdf5-dev libusb-1.0-0-dev \
  libhackrf-dev libairspy-dev libairspyhf-dev libad9361-dev libiio-dev libbladerf-dev \
  libomp-dev ocl-icd-opencl-dev

say "RTL-SDR Blog driver packages (SatDump is built against them)"
if [ "$(dpkg-query -W -f='${Version}' librtlsdr-dev 2>/dev/null)" != "$rtl_version" ]; then
  rm -rf "$WORK/rtl" && mkdir -p "$WORK/rtl" && cd "$WORK/rtl"
  git init -q src && cd src
  git remote add origin https://github.com/rtlsdrblog/rtl-sdr-blog
  git fetch -q --depth 1 origin "$rtl_commit"
  git -c advice.detachedHead=false checkout -q FETCH_HEAD
  { printf 'rtl-sdr (%s) unstable; urgency=medium\n\n' "$rtl_version"
    printf '  * RTL-SDR Blog driver %s, packaged by Raspberry-LRPT.\n\n' "${rtl_commit:0:7}"
    printf ' -- Raspberry-LRPT <raspberry-lrpt@localhost>  %s\n\n' "$(date -R)"
    cat debian/changelog; } > debian/changelog.new && mv debian/changelog.new debian/changelog
  dpkg-buildpackage -b --no-sign -uc -us > "$WORK/rtl/build.log" 2>&1 || die "RTL-SDR Blog build failed: $WORK/rtl/build.log"
  sudo apt-get install -y -q --allow-downgrades "$WORK"/rtl/librtlsdr0_*.deb "$WORK"/rtl/librtlsdr-dev_*.deb "$WORK"/rtl/rtl-sdr_*.deb
fi

say "SatDump source"
rm -rf "$WORK/src" "$WORK/build" && mkdir -p "$WORK/src" "$WORK/build"
cd "$WORK/src"
git init -q && git remote add origin https://github.com/SatDump/SatDump
git fetch -q --depth 1 origin "$satdump_commit"
git -c advice.detachedHead=false checkout -q FETCH_HEAD
git submodule update --init --depth 1 -q 2>/dev/null || true

say "Building (this takes a while)"
cd "$WORK/build"
cmake "$WORK/src" -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr > "$WORK/cmake.log" 2>&1 \
  || die "cmake failed: $WORK/cmake.log"
make -j"$JOBS" > "$WORK/make.log" 2>&1 || die "make failed (if 'Killed', add swap or use -j 1): $WORK/make.log"
make package > "$WORK/package.log" 2>&1 || die "make package failed: $WORK/package.log"

deb=$(ls "$WORK"/build/satdump*.deb | head -1)
[ -n "$deb" ] || die "no .deb was made"
cp "$deb" "$out"
echo
echo "Done: $out ($(du -h "$out" | cut -f1))"
echo "  Package: $(dpkg-deb -f "$out" Package) $(dpkg-deb -f "$out" Version) $(dpkg-deb -f "$out" Architecture)"
echo "  Now run: cd $REPO && ./install_and_upgrade.sh"
echo "  To share it with other ${codename} stations, add it to the repository's software/ folder."
rm -rf "$WORK/src" "$WORK/build" "$WORK/rtl"
