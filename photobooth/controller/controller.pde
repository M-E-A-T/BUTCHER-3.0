// Controller: flips between the photobooth modes with the arrow keys,
// without closing them.
//
// On start it opens all four modes once. They start hidden and paused; the
// controller shows the current one and hides the rest, so switching is instant.
// Left/right in this window, or in any mode's window (forwarded over UDP 9100,
// see modes/*/switcher.pde), moves to the previous/next mode.
//
// Audio: the controller takes the audio server's UDP 9000 and relays every packet
// to each mode's own port (organism 9001, pixelz 9002, thermal 9003, fft 9004),
// so all of them keep getting audio while open.
//
// Quitting the controller closes all modes.

import java.net.*;
import java.io.File;

String[] modes = { "organism", "pixelz", "thermal", "fft" };   // same order as SW_MODES in switcher.pde
int current = 0;
boolean[] ready = new boolean[4];
Process[] procs = new Process[4];

final String PROCESSING = "/Applications/Processing.app/Contents/MacOS/Processing";
final int CTRL_PORT = 9100;
final int AUDIO_PORT = 9000;
DatagramSocket ctrlSock, audioSock;
volatile int pendingStep = 0;     // set by the UDP thread, applied in draw()
volatile int pendingHello = -1;   // a mode that just finished starting up

void settings() {
  size(460, 260);
}

void setup() {
  surface.setTitle("Controller");
  textFont(createFont("SansSerif", 20));
  for (String m : modes) killStray(m);   // nothing left over from earlier runs
  startControl();                        // must be up before the modes start: they check for it
  startRelay();
  for (int i = 0; i < modes.length; i++) launch(i);
}

void draw() {
  int hello = pendingHello;
  if (hello >= 0) {
    pendingHello = -1;
    ready[hello] = true;
    tell(hello, hello == current ? "show" : "hide");
  }
  int step = pendingStep;
  if (step != 0) { pendingStep = 0; go(step); }

  background(23, 17, 28);
  fill(168, 144, 158);
  textSize(13);
  text("← / →  switch mode   (works in the mode window too)", 20, 28);
  for (int i = 0; i < modes.length; i++) {
    boolean on = i == current;
    textSize(22);
    fill(on ? color(230, 57, 70) : color(243, 233, 238, 120));
    text((on ? "▶ " : "   ") + modes[i], 28, 72 + i * 36);
    textSize(13);
    fill(168, 144, 158);
    boolean dead = procs[i] != null && !procs[i].isAlive();
    text(dead ? "stopped" : ready[i] ? "open" : "starting…", 200, 70 + i * 36);
  }
}

void keyPressed() {
  if (key == CODED && keyCode == RIGHT) go(1);
  if (key == CODED && keyCode == LEFT) go(-1);
}

void go(int step) {
  int prev = current;
  current = (current + step + modes.length) % modes.length;
  println("Showing " + modes[current]);
  tell(current, "show");   // show the new one first so there's no gap
  tell(prev, "hide");
}

void tell(int i, String msg) {
  try {
    byte[] b = msg.getBytes("US-ASCII");
    ctrlSock.send(new DatagramPacket(b, b.length, InetAddress.getLoopbackAddress(), 9101 + i));
  } catch (Exception e) {
    println("Couldn't reach " + modes[i] + ": " + e.getMessage());
  }
}

void launch(int i) {
  String dir = new File(sketchPath("../modes/" + modes[i])).getAbsolutePath();
  println("Opening " + modes[i]);
  try {
    ProcessBuilder pb = new ProcessBuilder(PROCESSING, "cli", "--sketch=" + dir, "--run");
    pb.inheritIO();
    procs[i] = pb.start();
  } catch (Exception e) {
    println("Couldn't open " + modes[i] + ": " + e.getMessage());
  }
}

// Mode sketches ignore a normal quit, so force-close them.
void killStray(String mode) {
  try {
    new ProcessBuilder("pkill", "-9", "-f", "Xdock:name=" + mode + " ").start().waitFor();
  } catch (Exception e) { }
}

// Arrows and "hello <mode>" from the modes.
void startControl() {
  try {
    ctrlSock = new DatagramSocket(CTRL_PORT, InetAddress.getLoopbackAddress());
  } catch (Exception e) {
    println("Controller: can't listen on UDP " + CTRL_PORT + " (" + e.getMessage() + ") - is another controller running?");
    exit();
    return;
  }
  Thread t = new Thread(new Runnable() {
    public void run() {
      byte[] buf = new byte[64];
      DatagramPacket pkt = new DatagramPacket(buf, buf.length);
      while (!ctrlSock.isClosed()) {
        try {
          pkt.setLength(buf.length);
          ctrlSock.receive(pkt);
          String msg = new String(buf, 0, pkt.getLength(), "US-ASCII").trim();
          if (msg.equals("next")) pendingStep = 1;
          else if (msg.equals("prev")) pendingStep = -1;
          else if (msg.startsWith("hello ")) {
            int i = java.util.Arrays.asList(modes).indexOf(msg.substring(6));
            if (i >= 0) { pendingHello = i; println(modes[i] + " is open"); }
          }
        } catch (Exception e) { }
      }
    }
  });
  t.setDaemon(true);
  t.start();
}

// Audio server (UDP 9000) -> every mode's own port.
void startRelay() {
  try {
    audioSock = new DatagramSocket(null);
    audioSock.setReuseAddress(false);
    audioSock.bind(new InetSocketAddress(AUDIO_PORT));
  } catch (Exception e) {
    println("Controller: can't take UDP " + AUDIO_PORT + " (" + e.getMessage() + "); modes get no audio");
    return;
  }
  Thread t = new Thread(new Runnable() {
    public void run() {
      byte[] buf = new byte[65536];
      DatagramPacket in = new DatagramPacket(buf, buf.length);
      InetAddress lo = InetAddress.getLoopbackAddress();
      while (!audioSock.isClosed()) {
        try {
          in.setLength(buf.length);
          audioSock.receive(in);
          for (int i = 0; i < modes.length; i++)
            audioSock.send(new DatagramPacket(buf, in.getLength(), lo, 9001 + i));
        } catch (Exception e) { }
      }
    }
  });
  t.setDaemon(true);
  t.start();
  println("Relaying audio from UDP " + AUDIO_PORT + " to 9001-9004");
}

void dispose() {
  for (Process p : procs) if (p != null) {
    p.descendants().forEach(ph -> ph.destroyForcibly());
    p.destroyForcibly();
  }
  for (String m : modes) killStray(m);
  if (ctrlSock != null) ctrlSock.close();
  if (audioSock != null) audioSock.close();
}
