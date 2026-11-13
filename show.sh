#!/bin/bash
# Show launcher: opens a web page (http://127.0.0.1:8770) that brings the show
# up in order — 1. local audio server, 2. pyramid wall, 3. photobooth — keeps
# track of which step it's on, and can relaunch any single step.
#   ./show.sh               # start the launcher and open the page
#   PORT=8771 ./show.sh     # another port
# Ctrl+C quits the launcher only; whatever it started keeps running.
# Code: show/launcher.py (server) and show/index.html (page). Logs: show/logs/.
cd "$(dirname "$0")" || exit 1
# Tools the steps need: cargo (rustup), ansible-playbook (Homebrew).
export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
PORT="${PORT:-8770}"
URL="http://127.0.0.1:$PORT"

# Already running? Just open the page.
if curl -s -o /dev/null --max-time 1 "$URL/api/state"; then
  echo "show launcher already running: $URL"
  open "$URL"
  exit 0
fi

for tool in python3 ansible-playbook cargo; do
  command -v "$tool" >/dev/null || echo "warning: $tool not found on PATH" >&2
done

exec python3 show/launcher.py --port "$PORT"
