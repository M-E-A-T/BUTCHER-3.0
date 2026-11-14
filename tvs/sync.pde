// Keeps every TV screen on the same picture.
//
// One laptop is the leader (TVS_LEADER=1, set by runTvs.yml on the first host
// of the [tvs] group). It runs the show logic as usual and, every frame, sends
// its state to the others (TVS_PEERS) on UDP 9001: slide, effect, effect zone,
// filter, titlecard, contour position, glitch beat phase, kaleido size, and
// its show clock. Followers apply that state instead of deciding for
// themselves, and animate from the leader's clock. A follower that hears
// nothing for SYNC_TIMEOUT_MS runs on its own until the leader is back.

final int SYNC_PORT = 9001;
final int SYNC_TIMEOUT_MS = 2000;

boolean syncLeader = false;
InetSocketAddress[] syncPeers = new InetSocketAddress[0];
DatagramSocket syncOut, syncIn;

// Latest leader state (written by the listener thread, read in draw()).
volatile String syncLatest = null;
volatile int syncReceivedAt = -100000;

// Shared show clock: the leader's seconds, extrapolated between packets.
float syncLeaderTime = 0;
int syncLeaderTimeAt = 0;

// Values the followers take over (used by the effects when following).
float glitchBeatPhase = 0;

void startSync() {
  syncLeader = "1".equals(System.getenv("TVS_LEADER"));
  String peers = System.getenv("TVS_PEERS");
  if (syncLeader) {
    ArrayList<InetSocketAddress> list = new ArrayList<InetSocketAddress>();
    if (peers != null) for (String p : peers.split(",")) {
      if (p.trim().length() > 0) list.add(new InetSocketAddress(p.trim(), SYNC_PORT));
    }
    syncPeers = list.toArray(new InetSocketAddress[0]);
    try { syncOut = new DatagramSocket(); } catch (Exception e) { println("sync: can't send: " + e); }
    println("sync: leader, sending to " + syncPeers.length + " screens");
    return;
  }
  try {
    syncIn = new DatagramSocket(null);
    syncIn.setReuseAddress(true);
    syncIn.bind(new InetSocketAddress(SYNC_PORT));
  } catch (Exception e) {
    println("sync: can't listen on UDP " + SYNC_PORT + " (" + e.getMessage() + "); running alone");
    return;
  }
  Thread t = new Thread(new Runnable() {
    public void run() {
      byte[] buf = new byte[1024];
      DatagramPacket pkt = new DatagramPacket(buf, buf.length);
      while (!syncIn.isClosed()) {
        try {
          pkt.setLength(buf.length);
          syncIn.receive(pkt);
          String s = new String(buf, 0, pkt.getLength(), "US-ASCII");
          if (s.startsWith("TVS1 ")) {
            syncLatest = s;
            syncReceivedAt = millis();
          }
        } catch (Exception e) {
        }
      }
    }
  });
  t.setDaemon(true);
  t.start();
  println("sync: follower, listening on UDP " + SYNC_PORT);
}

// True while a follower has fresh leader state.
boolean following() {
  return !syncLeader && millis() - syncReceivedAt < SYNC_TIMEOUT_MS;
}

// Seconds on the shared show clock (all animation runs off this).
float showTime() {
  if (following()) return syncLeaderTime + (millis() - syncLeaderTimeAt) / 1000.0;
  return millis() / 1000.0;
}

// Leader: send this frame's state to every follower.
void sendSync() {
  if (!syncLeader || syncOut == null || syncPeers.length == 0) return;
  String s = "TVS1 " + nf(millis() / 1000.0, 0, 3)
    + " " + slideIndex
    + " " + (photoInA ? 1 : 0)
    + " " + currentEffectId
    + " " + manualFilterChoice
    + " " + (titlecardsEnabled ? 1 : 0)
    + " " + titlecardSelection
    + " " + contourAnimationOffset
    + " " + contourSteps
    + " " + glitchBeatPhase
    + " " + kaleidoLowEnv;
  byte[] b = s.getBytes();
  for (InetSocketAddress a : syncPeers) {
    try { syncOut.send(new DatagramPacket(b, b.length, a)); } catch (Exception e) { }
  }
}

// Follower: take over the leader's state. Called in draw() after the local
// logic, so the leader's values win.
String syncApplied = null;
void applySync() {
  if (!following()) return;
  String s = syncLatest;
  if (s == null) return;
  String[] f = s.split(" ");
  if (f.length < 12) return;
  try {
    if (!s.equals(syncApplied)) {
      syncLeaderTime = float(f[1]);
      syncLeaderTimeAt = syncReceivedAt;
    }
    syncApplied = s;
    int slide = int(f[2]);
    if (slide != slideIndex && slide >= 0 && slide < slides.size()) startSlide(slide);
    photoInA = f[3].equals("1");
    int effectId = int(f[4]);
    if (effectId != currentEffectId) makeEffects(effectId);
    int filter = int(f[5]);
    if (filter != manualFilterChoice && filter >= 0 && filter < FILTER_NAMES.length) {
      manualFilterChoice = filter;
      manualFilter = makeFilter(filter);
    }
    boolean titleOn = f[6].equals("1");
    if (titleOn != titlecardsEnabled) setTitlecardsEnabled(titleOn);
    titlecardSelection = constrain(int(f[7]), 1, titlecardNames.length);
    contourAnimationOffset = float(f[8]);
    contourSteps = int(f[9]);
    glitchBeatPhase = float(f[10]);
    kaleidoLowEnv = float(f[11]);
  } catch (Exception e) {
    // malformed packet: keep the current state
  }
}
