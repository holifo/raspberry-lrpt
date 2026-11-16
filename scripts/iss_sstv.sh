#!/bin/bash
#
# Kept for v1.28.0's instructions: the same as "scripts/switch.sh iss on|off"
# (no argument: what is on).
here="$(dirname "$(readlink -f "$0")")"
[ $# -eq 0 ] && exec "$here/switch.sh"
exec "$here/switch.sh" iss "$@"
