#!/bin/bash
# Record a session of the wandering eye: the sketch window, a mirrored live
# camera view in the top-right corner, and the music from BlackHole.
#   ./record.sh            # start; Ctrl+C (or ./record.sh stop) to finish
#   ./record.sh stop       # finish a recording started elsewhere
# Output: ~/Desktop/wandering_eye_session_<date>.mp4
#
# Audio is recorded by tools/audiorec (a tiny Swift recorder), not ffmpeg:
# ffmpeg's avfoundation audio input keeps one buffer and drops chunks when it
# reads late (clicks). audiorec writes the capture-clock time of its first
# sample; ffmpeg keeps the same clock on the video (-copyts), so the two line
# up exactly when merged.
# The sketch window must be open, not moved, and not covered while recording.

PIDFILE="${TMPDIR:-/tmp}/wandering_eye_record.pid"
if [ "$1" = "stop" ]; then
  if [ -f "$PIDFILE" ] && kill -TERM "$(cat "$PIDFILE")" 2>/dev/null; then
    echo "stopping..."
  else
    echo "not recording"
  fi
  exit 0
fi
echo $$ > "$PIDFILE"

AUDIO_DEV="${AUDIO_DEV:-BlackHole 2ch}"   # avfoundation audio device name
SCREEN_DEV="${SCREEN_DEV:-Capture screen 0}"
CAM_DEV="${CAM_DEV:-FaceTime HD Camera}"
CAM_W=384                                  # overlay width in the 1280x720 video

cd "$(dirname "$0")" || exit 1
AUDIOREC=tools/audiorec
if [ ! -x "$AUDIOREC" ] || [ tools/audiorec.swift -nt "$AUDIOREC" ]; then
  echo "building $AUDIOREC..."
  swiftc -O tools/audiorec.swift -o "$AUDIOREC" 2>/dev/null || { echo "could not build $AUDIOREC" >&2; exit 1; }
fi

TMP=$(mktemp -d)
OUT="$HOME/Desktop/wandering_eye_session_$(date +%Y%m%d-%H%M%S).mp4"

# Sketch window content area in points (window minus its 28 pt title bar).
read -r WX WY WW WH < <(osascript -e '
  tell application "System Events"
    repeat with p in (every process whose background only is false)
      repeat with w in (every window of p)
        if name of w is "wandering_eye" then
          set {x, y} to position of w
          set {ww, hh} to size of w
          return (x as text) & " " & ((y + 28) as text) & " " & (ww as text) & " " & ((hh - 28) as text)
        end if
      end repeat
    end repeat
  end tell' 2>/dev/null)
if [ -z "$WH" ]; then echo "wandering_eye window not found; is the sketch running?" >&2; exit 1; fi

# Screen capture is in pixels; window position is in points. Get the scale.
PTS_W=$(osascript -e 'tell application "Finder" to item 3 of (get bounds of window of desktop)')
ffmpeg -nostdin -v error -f avfoundation -i "$SCREEN_DEV:none" -frames:v 1 -y "$TMP/s.png"
PX_W=$(ffprobe -v error -show_entries stream=width -of csv=p=0 "$TMP/s.png")
S=$(echo "$PX_W / $PTS_W" | bc -l)
CROP=$(printf "%d:%d:%d:%d" $(echo "$WW*$S/1; $WH*$S/1; $WX*$S/1; $WY*$S/1" | bc))
echo "window ${WW}x${WH} at ${WX},${WY} pt -> crop $CROP px"
# Bring the sketch window to the front so nothing covers it.
osascript -e '
  tell application "System Events"
    repeat with p in (every process whose background only is false)
      repeat with w in (every window of p)
        if name of w is "wandering_eye" then
          set frontmost of p to true
          perform action "AXRaise" of w
          return
        end if
      end repeat
    end repeat
  end tell' >/dev/null 2>&1

"$AUDIOREC" "$AUDIO_DEV" "$TMP/a.wav" 2>/dev/null &
A=$!
ffmpeg -nostdin -hide_banner -loglevel error -y \
  -thread_queue_size 1024 -f avfoundation -capture_cursor 0 -framerate 30 -i "$SCREEN_DEV:none" \
  -thread_queue_size 1024 -f avfoundation -framerate 30 -video_size 1280x720 -i "$CAM_DEV:none" \
  -filter_complex "[0:v]crop=$CROP,scale=1280:720,fps=30[m];[1:v]hflip,scale=$CAM_W:-2[c];[m][c]overlay=W-w-16:16,format=yuv420p[v]" \
  -map "[v]" -c:v h264_videotoolbox -b:v 8M -copyts "$TMP/v.mkv" 2>&1 | grep -v "pixel format\|nv12\|0rgb\|bgr0\|uyvy\|yuyv\|objc\|Color range\|falling back" &
V=$(pgrep -n -f "$TMP/v.mkv")

# ffmpeg finishes its file cleanly on TERM. (Background jobs of a script
# ignore INT, so INT would never reach them.)
stop() { kill -TERM $A $V 2>/dev/null; }
trap stop INT TERM
echo "recording... Ctrl+C or ./record.sh stop to finish"
wait $A 2>/dev/null; wait 2>/dev/null
trap - INT TERM
rm -f "$PIDFILE"

# Merge: shift the audio by its start-time difference to the video.
AS=$(cat "$TMP/a.wav.start")
VS=$(ffprobe -v error -show_entries format=start_time -of csv=p=0 "$TMP/v.mkv")
OFF=$(printf "%.6f" "$(echo "$AS - $VS" | bc -l)")
echo "merging (audio offset ${OFF}s)..."
ffmpeg -nostdin -hide_banner -loglevel error -y -i "$TMP/v.mkv" -itsoffset "$OFF" -i "$TMP/a.wav" \
  -map 0:v -map 1:a -c:v copy -c:a aac -b:a 192k -shortest -movflags +faststart "$OUT" \
  && rm -rf "$TMP" && echo "saved $OUT" \
  || echo "merge failed; raw files kept in $TMP" >&2
