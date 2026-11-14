// Audio from the BUTCHER audio server: onset-driven effect zone swap, plus
// band levels and per-band onset counters for the thermal filter.
// UDP 9000, same feed the photobooth uses. The effect flips between the upper
// and lower zone (the photo shows in the other) every `onsetSwapEvery` onsets on the chosen band.

import java.net.*;
import java.nio.ByteBuffer;

final int OSC_PORT = 9000;
final String[] ONSET_BANDS = { "Any", "Low", "Mid", "High" };

int onsetSwapEvery = 16;   // 0 = off
int onsetBandChoice = 1;   // index into ONSET_BANDS; Low = kicks
volatile int onsetCount = 0;
volatile float oscLow = 0, oscMid = 0, oscHigh = 0;        // 0..1, /audio/lmh
volatile int lowHits = 0, midHits = 0, highHits = 0;       // onsets per band
volatile float oscBpm = 0;   // /audio/bpm, 60..180, 0 = not locked / silence
// /tvs/title ,s <name> from the show launcher: a titlecard name (shows it),
// or "OFF" (hides titlecards). Applied in draw() by applyTitleRequest().
volatile String requestedTitle = null;
DatagramSocket oscSock;

void startOnsetListener() {
  try {
    oscSock = new DatagramSocket(null);
    oscSock.setReuseAddress(true);
    oscSock.bind(new InetSocketAddress(OSC_PORT));
  } catch (Exception e) {
    println("OSC: can't listen on UDP " + OSC_PORT + " (" + e.getMessage() + "); no onset zone swaps");
    return;
  }
  Thread t = new Thread(new Runnable() {
    public void run() {
      byte[] buf = new byte[65536];
      DatagramPacket pkt = new DatagramPacket(buf, buf.length);
      while (!oscSock.isClosed()) {
        try {
          pkt.setLength(buf.length);
          oscSock.receive(pkt);
          int n = pkt.getLength();
          if (n >= 20 && new String(buf, 0, 11, "US-ASCII").equals("/tvs/title\0")) {
            int end = 16;
            while (end < n && buf[end] != 0) end++;
            requestedTitle = new String(buf, 16, end - 16, "UTF-8");
          } else if (n >= 32 && new String(buf, 0, 10, "US-ASCII").equals("/audio/lmh")) {
            ByteBuffer bb = ByteBuffer.wrap(buf, 20, 12);
            oscLow = bb.getFloat();
            oscMid = bb.getFloat();
            oscHigh = bb.getFloat();
          } else if (n >= 20 && new String(buf, 0, 10, "US-ASCII").equals("/audio/bpm")) {
            oscBpm = ByteBuffer.wrap(buf, 16, 4).getFloat();
          } else if (n >= 16 && new String(buf, 0, 13, "US-ASCII").equals("/audio/onset/")) {
            int band = buf[13] == 'l' ? 1 : buf[13] == 'm' ? 2 : buf[13] == 'h' ? 3 : -1;
            if (band == 1) lowHits++;
            else if (band == 2) midHits++;
            else if (band == 3) highHits++;
            if (band > 0 && (onsetBandChoice == 0 || onsetBandChoice == band)) onsetCount++;
          }
        } catch (Exception e) {
          // socket closed on exit, or a malformed packet: keep going / stop
        }
      }
    }
  });
  t.setDaemon(true);
  t.start();
  println("OSC: listening on UDP " + OSC_PORT + " for onsets");
}

// Called once per frame from draw().
void updateOnsetSwap() {
  if (onsetSwapEvery <= 0) {
    onsetCount = 0;
    return;
  }
  if (onsetCount >= onsetSwapEvery) {
    onsetCount = 0;
    photoInA = !photoInA;
    println("Onsets: effect -> " + (photoInA ? "upper" : "lower") + " zone");
  }
}

// Filter change on kicks: every 8..16 low onsets (re-rolled each time) switch
// to a different filter (None counts as one). Overrides auto mode's timed filters.
boolean onsetFilters = true;
final int FILTER_ONSETS_MIN = 8, FILTER_ONSETS_MAX = 16;
int filterLowSeen = 0;
int filterOnsetTarget = FILTER_ONSETS_MIN;

void rollFilterOnsetTarget() {
  filterLowSeen = lowHits;
  filterOnsetTarget = FILTER_ONSETS_MIN + int(random(FILTER_ONSETS_MAX - FILTER_ONSETS_MIN + 1));
}

// Called once per frame from draw().
void updateOnsetFilter() {
  if (!onsetFilters || !filtersEnabled) {
    filterLowSeen = lowHits;
    return;
  }
  if (lowHits - filterLowSeen < filterOnsetTarget) return;
  int n;
  do n = int(random(FILTER_NAMES.length)); while (n == manualFilterChoice);
  manualFilterChoice = n;
  manualFilter = makeFilter(n);
  println("Kicks: filter -> " + FILTER_NAMES[n] + " (after " + filterOnsetTarget + ")");
  rollFilterOnsetTarget();
}

// Next skyline image every `slideEveryKicks` low onsets (0 = off).
int slideEveryKicks = 32;
int slideLowSeen = 0;

// Called once per frame from draw().
void updateOnsetSlide() {
  if (slideEveryKicks <= 0) {
    slideLowSeen = lowHits;
    return;
  }
  if (lowHits - slideLowSeen < slideEveryKicks) return;
  slideLowSeen = lowHits;
  startSlide((slideIndex + 1) % slides.size());
}

// Applies a titlecard sent by the show launcher (main thread).
void applyTitleRequest() {
  String name = requestedTitle;
  if (name == null) return;
  requestedTitle = null;
  if (name.equalsIgnoreCase("OFF")) {
    if (titlecardsEnabled) setTitlecardsEnabled(false);
    return;
  }
  for (int i = 0; i < titlecardNames.length; i++) {
    if (titlecardNames[i].equalsIgnoreCase(name)) {
      titlecardSelection = i + 1;
      if (!titlecardsEnabled) setTitlecardsEnabled(true);
      println("Titlecard from launcher: " + titlecardNames[i]);
      return;
    }
  }
  println("Titlecard from launcher: unknown name " + name);
}
