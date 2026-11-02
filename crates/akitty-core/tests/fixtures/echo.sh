#!/bin/sh
set -eu
# Measure kernel PTY echo without login banners, prompts or readline redraws.
/bin/stty -icanon echo min 1 time 0
printf '\033[2J\033[HECHO_READY\r\n'
exec /bin/cat >/dev/null
