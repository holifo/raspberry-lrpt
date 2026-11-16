#!/bin/bash
#
# Fix the Depends line of a SatDump .deb made by "make package".
#
#   scripts/tools/fix_satdump_deb_depends.sh FILE.deb
#
# SatDump's CPack settings use a fixed list of dependencies written for older Debian releases. On
# Trixie it names HDF5 packages that don't exist (libhdf5-103, libhdf5-hl-100…), so apt refuses the
# package ("Dependency is not satisfiable"). It also leaves out libraries that libsatdump_core.so
# links to (TIFF, curl, OpenCL, OpenMP). This rewrites the list from what the binaries really link to
# and rebuilds the .deb in place. Running it twice changes nothing.

set -e
deb="$1"
[ -f "$deb" ] || { echo "Usage: $0 FILE.deb"; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
dpkg-deb -R "$deb" "$tmp/pkg"
ctl="$tmp/pkg/DEBIAN/control"

# the HDF5 version the plugins link to: libhdf5_serial.so.<N>
hdf5=$(find "$tmp/pkg/usr" -name '*.so' -exec readelf -d {} \; 2>/dev/null \
       | grep -o 'libhdf5_serial\.so\.[0-9]*' | head -1 | sed 's/.*\.so\.//')

python3 - "$ctl" "$hdf5" <<'EOF'
import re, sys
ctl, hdf5 = sys.argv[1], sys.argv[2]
text = open(ctl).read()
m = re.search(r'^Depends: (.*)$', text, re.M)
deps = [d.strip() for d in m.group(1).split(',')] if m else []
if hdf5 == '310':   # HDF5 1.14 (Trixie): one package for each library
    i = next((n for n, d in enumerate(deps) if 'libhdf5' in d), len(deps))
    deps = [d for d in deps if 'libhdf5' not in d]
    deps[i:i] = ['libhdf5-310', 'libhdf5-hl-310']
# libsatdump_core.so links to these; the CPack list leaves them out
for extra in ('libtiff6', 'libcurl4t64 | libcurl4', 'ocl-icd-libopencl1 | libopencl1', 'libgomp1'):
    first = extra.split(' |')[0]
    if not any(d.split(' |')[0].split(' (')[0] == first for d in deps):
        deps.append(extra)
line = 'Depends: ' + ', '.join(deps)
text = re.sub(r'^Depends: .*$', line, text, flags=re.M) if m else text.rstrip('\n') + '\n' + line + '\n'
open(ctl, 'w').write(text)
print(line)
EOF

dpkg-deb --root-owner-group -Zxz -b "$tmp/pkg" "$tmp/out.deb" > /dev/null
mv "$tmp/out.deb" "$deb"
