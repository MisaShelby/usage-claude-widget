#!/bin/sh
# README screenshots of the GNOME extension, taken in a headless GNOME Shell 48 with sample
# data (English UI). Your session is not touched: separate home, D-Bus and runtime folders.
# Needs gnome-shell, dbus-run-session and python3 with Pillow.
#   tools/screenshots/linux.sh [output folder, default docs/screenshots]
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
OUT=${1:-$ROOT/docs/screenshots}
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/cbs.XXXXXX") # short path: Wayland sockets need < 108 bytes
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/home/.local/share/gnome-shell/extensions" "$WORK/run" "$WORK/shots"
chmod 700 "$WORK/run"
cp -r "$ROOT/tools/screenshots/shot@claude-budget" "$WORK/home/.local/share/gnome-shell/extensions/"

cat > "$WORK/inner.sh" <<'INNER'
cd "$HOME"
"$ROOT/install.sh" > /dev/null
gsettings set org.gnome.shell enabled-extensions "['claude-budget@misashelby', 'shot@claude-budget']"
gsettings set org.gnome.shell disable-user-extensions false
gsettings set org.gnome.shell welcome-dialog-last-shown-version '999'
gsettings set org.gnome.desktop.interface color-scheme 'prefer-dark'
gnome-shell --headless --no-x11 --virtual-monitor 1600x900 > "$SHOT_DIR/shell.log" 2>&1 &
PID=$!
i=0
while [ ! -e "$SHOT_DIR/done" ] && [ $i -lt 120 ]; do sleep 1; i=$((i + 1)); done
kill $PID
wait $PID 2> /dev/null || true
INNER

env -i HOME="$WORK/home" USER="${USER:-user}" ${TZ:+TZ="$TZ"} \
    LANG=en_US.UTF-8 LANGUAGE=en LC_ALL=en_US.UTF-8 PATH=/usr/local/bin:/usr/bin:/bin \
    XDG_CONFIG_HOME="$WORK/home/.config" XDG_DATA_HOME="$WORK/home/.local/share" \
    XDG_STATE_HOME="$WORK/home/.local/state" XDG_CACHE_HOME="$WORK/home/.cache" \
    XDG_RUNTIME_DIR="$WORK/run" SHOT_DIR="$WORK/shots" ROOT="$ROOT" \
    dbus-run-session -- sh "$WORK/inner.sh" > /dev/null 2>&1

python3 "$ROOT/tools/screenshots/crop.py" "$WORK/shots" "$OUT"
