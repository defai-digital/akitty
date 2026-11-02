#!/bin/sh
set -eu
# Signal readiness after terminal setup; commands run without interactive prompt redraws.
/bin/stty -echo
printf '\033[2J\033[HPANE_READY\n'
while IFS= read -r line; do
    /bin/sh -c "$line"
done
