// Mode switching with the controller sketch (photobooth/controller).
// Run on its own, this mode behaves as before (audio on UDP 9000).
// When the controller is running, all modes stay open and the controller just
// shows one and hides the others:
//  - the controller relays the audio from 9000 to each mode's own port (9001..9004)
//  - it sends "show" / "hide" to the mode's control port (9101..9104)
//  - hidden modes stop their webcam (only one sketch can use it), shown modes restart it
//  - left/right arrows here are forwarded to the controller on 9100.
// Same file in every mode; the mode is identified by its folder name.

String[] SW_MODES = { "organism", "pixelz", "thermal", "fft" };
int swIdx = -2;          // -2 = not looked up yet
int swManaged = -1;      // -1 = not checked yet, 0 = standalone, 1 = under the controller

int swIndex() {
  if (swIdx == -2) {
    String name = new java.io.File(sketchPath()).getName();
    swIdx = java.util.Arrays.asList(SW_MODES).indexOf(name);
  }
  return swIdx;
}

// The controller holds UDP 9100 on loopback; if we can't take it, it's running.
boolean swUnderController() {
  if (swManaged < 0) {
    swManaged = 1;
    try {
      java.net.DatagramSocket probe = new java.net.DatagramSocket(9100, java.net.InetAddress.getLoopbackAddress());
      probe.close();
      swManaged = 0;
    } catch (Exception e) { }
    if (swIndex() < 0) swManaged = 0;
  }
  return swManaged == 1;
}

// Audio port: 9000 on its own, this mode's relay port under the controller.
int swOscPort() {
  return swUnderController() ? 9001 + swIndex() : 9000;
}

// Call at the end of setup(): under the controller, start hidden and paused and
// wait for "show".
void swSetup() {
  if (!swUnderController()) return;
  surface.setVisible(false);
  noLoop();
  if (cam != null) cam.stop();   // only one sketch can use the webcam: hidden modes let go of it
  final int port = 9101 + swIndex();
  Thread t = new Thread(new Runnable() {
    public void run() {
      try {
        java.net.DatagramSocket s = new java.net.DatagramSocket(port, java.net.InetAddress.getLoopbackAddress());
        byte[] buf = new byte[64];
        java.net.DatagramPacket pkt = new java.net.DatagramPacket(buf, buf.length);
        swSend("hello " + SW_MODES[swIndex()]);
        while (true) {
          pkt.setLength(buf.length);
          s.receive(pkt);
          String msg = new String(buf, 0, pkt.getLength(), "US-ASCII").trim();
          if (msg.equals("show")) {
            loop();
            surface.setVisible(true);
            Object w = surface.getNative();
            if (w instanceof com.jogamp.newt.Window) ((com.jogamp.newt.Window) w).requestFocus();
            Thread.sleep(250);   // give the mode being hidden time to release the webcam
            if (cam != null) { cam.stop(); cam.start(); }
          } else if (msg.equals("hide")) {
            if (cam != null) cam.stop();
            noLoop();
            surface.setVisible(false);
          }
        }
      } catch (Exception e) {
        println("switcher: " + e.getMessage());
      }
    }
  });
  t.setDaemon(true);
  t.start();
}

void swSend(String text) {
  try {
    byte[] msg = text.getBytes("US-ASCII");
    java.net.DatagramSocket s = new java.net.DatagramSocket();
    s.send(new java.net.DatagramPacket(msg, msg.length, java.net.InetAddress.getLoopbackAddress(), 9100));
    s.close();
  } catch (Exception e) {
    println("controller not reachable: " + e.getMessage());
  }
}

// Left/right arrows: tell the controller to switch mode.
boolean sendSwitch() {
  if (key != CODED || (keyCode != LEFT && keyCode != RIGHT)) return false;
  swSend(keyCode == LEFT ? "prev" : "next");
  return true;
}
