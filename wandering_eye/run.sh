#!/bin/bash
# Start the wandering eye: camera person detector (eye_yolo.py, chooses who
# to watch) + the Processing sketch, full screen. Ctrl+C / Esc stops both.
# Mac or the Linux show laptops.
#   ./run.sh           # normal
#   ./run.sh --show    # also open the detector's debug window (red box = chosen)
# Audio comes in over OSC on UDP 9000 like the pyramid wall: run the audio
# server on this machine, or broadcast to the show network.
cd "$(dirname "$0")" || exit 1

# Python env, first run only (onnxruntime + opencv + numpy; the model is in models/).
if [ ! -x .venv/bin/python ] || ! .venv/bin/python -c "import onnxruntime, cv2" 2>/dev/null; then
  echo "setting up .venv..."
  rm -rf .venv
  if command -v uv >/dev/null; then
    uv venv -p 3.12 .venv && uv pip install -p .venv/bin/python -r requirements.txt || exit 1
  else
    python3 -m venv .venv && .venv/bin/pip install -q -r requirements.txt || exit 1
  fi
fi

if [ "$(uname)" = Darwin ]; then
  PROCESSING=/Applications/Processing.app/Contents/MacOS/Processing
else
  PROCESSING="$HOME/processing-4.5.7/Processing/bin/Processing"
  export DISPLAY="${DISPLAY:-:0}"
fi

.venv/bin/python -u eye_yolo.py "$@" &
Y=$!
trap 'kill $Y 2>/dev/null' EXIT INT TERM

# Once the sketch window is up, make it the frontmost app: macOS only hides
# the menu bar for the active app's fullscreen window.
if [ "$(uname)" = Darwin ]; then
  (
    for i in $(seq 60); do
      J=$(pgrep -f "PApplet.*wandering_eye" | head -1)
      [ -n "$J" ] && break; sleep 0.5
    done
    sleep 2
    [ -n "$J" ] && osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $J) to true" >/dev/null 2>&1
  ) &
fi
"$PROCESSING" cli --sketch="$PWD" --run
