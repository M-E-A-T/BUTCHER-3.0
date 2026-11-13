#!/bin/bash
# Start boothModes: photobooth (trigger -> countdown -> GIF -> playback -> QR) with the modesTogether looks.
# PS Move: square = thermal, triangle = fft, cross = pixelz, circle = organism. Optional arg ignored.
HERE="$(cd "$(dirname "$0")" && pwd)"
exec flatpak run --command=/app/share/processing/processing-java org.processing.processingide \
  --sketch="$HERE/boothModes" --run "$@"
