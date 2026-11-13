#!/usr/bin/env python3
"""
Bridge: reads the PS Move with psmoveapi and prints state lines to stdout,
for the Processing sketch in boothModes/ (which launches this automatically).

Output lines (only when something changes):
    CONNECTED bt|usb
    DISCONNECTED
    STATE <held buttons comma-separated or -> <trigger 0..1>
    BATTERY <0..5 = empty..full | CHARGING | CHARGED>

Commands it accepts on stdin (from the sketch):
    PULSE <ms>     rumble for that long (countdown ticks)
    QUIET 1|0      1 = don't rumble while buttons/trigger are held (so pulses stand out)
"""
import os, signal, sys, threading, time

HERE = os.path.dirname(os.path.abspath(__file__))
BASE = os.path.join(HERE, 'psmoveapi')
os.environ.setdefault('PSMOVEAPI_LIBRARY_PATH',
                      os.path.join(BASE, 'build-macos' if sys.platform == 'darwin' else 'build'))
sys.path.insert(0, os.path.join(BASE, 'bindings', 'python'))
import psmoveapi
from psmoveapi import Button

BUTTONS = [(Button.TRIANGLE, 'TRIANGLE'), (Button.CIRCLE, 'CIRCLE'), (Button.CROSS, 'CROSS'),
           (Button.SQUARE, 'SQUARE'), (Button.SELECT, 'SELECT'), (Button.START, 'START'),
           (Button.PS, 'PS'), (Button.MOVE, 'MOVE')]

# orb colour per button: same colours the sketch draws the shapes in (0..1 RGB)
COLORS = {'CROSS': (90, 150, 255), 'CIRCLE': (255, 80, 90), 'SQUARE': (240, 120, 220),
          'TRIANGLE': (60, 220, 160)}
OTHER = (230, 230, 230)   # SELECT / START / PS / MOVE


pulse_until = [0.0]
quiet = [False]


def read_commands():
    for line in sys.stdin:
        p = line.split()
        if not p:
            continue
        if p[0] == 'PULSE':
            ms = float(p[1]) if len(p) > 1 else 150
            pulse_until[0] = time.time() + ms / 1000
        elif p[0] == 'QUIET':
            quiet[0] = len(p) > 1 and p[1] == '1'


def emit(line):
    try:
        sys.stdout.write(line + '\n')
        sys.stdout.flush()
    except BrokenPipeError:  # sketch closed
        os._exit(0)


class Bridge(psmoveapi.PSMoveAPI):
    def __init__(self):
        super().__init__()
        self.last = None
        self.flash_at = 0
        self.armed = True
        self.order = []   # held buttons in press order; newest last = the big shape
        self.battery = None

    def on_connect(self, c):
        emit('CONNECTED ' + ('bt' if c.bluetooth else 'usb'))
        c.color = psmoveapi.RGB(0, 0.3, 0)

    def on_update(self, c):
        b = c.battery
        bat = 'CHARGING' if b == 0xEE else 'CHARGED' if b == 0xEF else str(max(0, min(5, b)))
        if bat != self.battery:
            self.battery = bat
            emit('BATTERY ' + bat)
        held = ','.join(n for m, n in BUTTONS if c.buttons & m) or '-'
        trig = round(c.trigger, 2)
        if (held, trig) != self.last:
            self.last = (held, trig)
            emit(f'STATE {held} {trig}')
        # track press order the same way the sketch does
        now = [n for m, n in BUTTONS if c.buttons & m]
        self.order = [b for b in self.order if b in now] + [b for b in now if b not in self.order]
        # orb = colour of the big shape on screen; trigger brightens the idle green
        if self.order:
            base = tuple(v / 255 for v in COLORS.get(self.order[-1], OTHER))
        else:
            g = 0.3 + 0.7 * c.trigger
            base = (0.0, g, 0.0)
        # camera flash on the ball too: same thresholds as the sketch
        if self.armed and c.trigger >= 0.9:
            self.flash_at, self.armed = time.time(), False
        elif c.trigger < 0.3:
            self.armed = True
        f = max(0.0, 1 - (time.time() - self.flash_at) / 0.4)  # white, fading over 0.4 s
        c.color = psmoveapi.RGB(*(v + (1 - v) * f for v in base))
        # rumble for as long as any button (or the trigger) is held
        held_any = any(c.buttons & m for m, _ in BUTTONS) or c.trigger > 0.05
        if time.time() < pulse_until[0]:
            c.rumble = 1.0
        else:
            c.rumble = 1.0 if held_any and not quiet[0] else 0.0

    def on_disconnect(self, c):
        emit('DISCONNECTED')
        self.last = None
        self.flash_at = 0
        self.order = []
        self.battery = None


running = [True]
def stop(*_): running[0] = False
signal.signal(signal.SIGINT, stop)
signal.signal(signal.SIGTERM, stop)

threading.Thread(target=read_commands, daemon=True).start()
api = Bridge()
emit('READY')
while running[0]:
    api.update()
