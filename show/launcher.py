#!/usr/bin/env python3
"""
Show launcher: brings the show up in order, from a small web page.

  1. audio      local audio server (realtime/), OSC out to the laptops
  2. pyramid    pyramid sketch on the six-screen wall (ansible/runPyramidWall.yml)
  3. tvs        skyline sketch on the TV laptops (ansible/runTvs.yml, [tvs] group)
  4. photobooth photobooth on 10.10.10.150 (ansible/runPhotobooth.yml)

Titlecards: the page lists the TV sketch's titlecard names (read from
tvs/skysets.pde); clicking one sends OSC /tvs/title <name> to every [tvs]
laptop on UDP 9000, so all screens switch together ("OFF" hides them).

Kill all (button, or `./show.sh kill`): stops a step that is still running,
runs ansible/killAll.yml on every laptop (pyramid, TV sketch, photobooth, OSC
monitor, NDI), stops the audio server on this Mac, then closes the launcher
(and with it ./show.sh). Its output goes to show/logs/killall.log.

"Launch all" runs the steps in order and stops at the first step that fails. Any
single step can be relaunched on its own, and "Continue" picks up from the
first step that isn't done. Progress is kept in show/state.json, so a page
refresh (or restarting the launcher) still shows where things are. Each
step's output goes to show/logs/<step>.log.

Started by ../show.sh; serves the page on http://127.0.0.1:8770 (local only).
Python standard library only.
"""
import argparse, json, os, re, signal, socket, subprocess, sys, threading, time, urllib.request, webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
REALTIME = os.path.join(ROOT, 'realtime')
ANSIBLE = os.path.join(ROOT, 'ansible')
LOGS = os.path.join(HERE, 'logs')
STATE_FILE = os.path.join(HERE, 'state.json')
AUDIO_BIN = os.path.join(REALTIME, 'engine', 'target', 'release', 'audio-server')
AUDIO_UI = 'http://127.0.0.1:8766'
HOSTS_INI = os.path.join(ANSIBLE, 'config', 'hosts.ini')
TVS_SKETCH = os.path.join(ROOT, 'tvs', 'skysets.pde')
OSC_PORT = 9000

STEPS = [
    {'id': 'audio', 'name': 'Audio server', 'detail': 'realtime/ on this Mac, UI on :8766'},
    {'id': 'pyramid', 'name': 'Pyramid wall', 'detail': 'runPyramidWall.yml, six laptops'},
    {'id': 'tvs', 'name': 'TV screens', 'detail': 'runTvs.yml, skyline sketch on the [tvs] laptops'},
    {'id': 'photobooth', 'name': 'Photobooth', 'detail': 'runPhotobooth.yml on 10.10.10.150'},
]
IDS = [s['id'] for s in STEPS]

current_proc = None              # subprocess of the step running right now (Kill all stops it)
killing = threading.Event()      # set once Kill all has started
lock = threading.Lock()          # guards `state`
run_lock = threading.Lock()      # only one run (sequence or single step) at a time
state = {
    'steps': {i: {'status': 'pending', 'started': None, 'ended': None, 'message': ''} for i in IDS},
    'current': None,             # step id being run right now
    'mode': None,                # 'all', 'continue' or 'single' while running
    'last_action': None,
    'title': None,               # last titlecard sent to the TV screens
}


# ---------------------------------------------------------------- state

def load_state():
    try:
        with open(STATE_FILE) as f:
            saved = json.load(f)
        for i in IDS:
            if i in saved.get('steps', {}):
                s = saved['steps'][i]
                # a step that was mid-run when the launcher stopped didn't finish
                if s.get('status') == 'running':
                    s['status'] = 'failed'
                    s['message'] = 'launcher stopped while this step was running'
                state['steps'][i].update(s)
        state['last_action'] = saved.get('last_action')
        state['title'] = saved.get('title')
    except (OSError, ValueError):
        pass


def save_state():
    tmp = STATE_FILE + '.tmp'
    with open(tmp, 'w') as f:
        json.dump({'steps': state['steps'], 'last_action': state['last_action'],
                   'title': state['title']}, f, indent=2)
    os.replace(tmp, STATE_FILE)


def set_step(step, **kw):
    with lock:
        state['steps'][step].update(kw)
        save_state()


# ---------------------------------------------------------------- steps

def log_path(step):
    return os.path.join(LOGS, step + '.log')


def run_cmd(step, cmd, cwd, log):
    """Run cmd, appending its output to the open log file. Returns the exit code."""
    log.write('\n$ ' + ' '.join(cmd) + '\n')
    log.flush()
    global current_proc
    p = subprocess.Popen(cmd, cwd=cwd, stdout=log, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL)
    current_proc = p
    try:
        return p.wait()
    finally:
        current_proc = None


def port_open(port, host='127.0.0.1'):
    try:
        with socket.create_connection((host, port), timeout=0.5):
            return True
    except OSError:
        return False


def audio_alive():
    return port_open(8766) and port_open(8765)


def step_audio(log):
    # build (quick when nothing changed)
    rc = run_cmd('audio', ['make', 'build'], REALTIME, log)
    if rc != 0:
        return False, 'build failed (make build exit %d)' % rc
    # stop any running copy, then start a fresh one detached from the launcher,
    # so the server keeps running if the launcher is closed
    subprocess.call(['pkill', '-f', 'engine/target/release/audio-server'])
    for _ in range(20):
        if not audio_alive():
            break
        time.sleep(0.25)
    log.write('\n$ %s   (in the background; its output: show/logs/audio-server.log)\n' % AUDIO_BIN)
    log.flush()
    out = open(os.path.join(LOGS, 'audio-server.log'), 'w')
    proc = subprocess.Popen([AUDIO_BIN], cwd=REALTIME, stdout=out, stderr=subprocess.STDOUT,
                            stdin=subprocess.DEVNULL, start_new_session=True)
    for _ in range(60):
        if proc.poll() is not None:
            return False, 'audio server exited with code %d (see audio-server.log)' % proc.returncode
        if audio_alive():
            try:
                urllib.request.urlopen(AUDIO_UI, timeout=2).read(1)
            except OSError:
                pass
            else:
                log.write('audio server up: UI %s\n' % AUDIO_UI)
                return True, 'running, UI on ' + AUDIO_UI
        time.sleep(0.5)
    return False, 'audio server did not open its ports within 30 s'


def playbook(step, name, log, extra=()):
    cmd = ['ansible-playbook', '-i', 'config/hosts.ini', name] + list(extra)
    rc = run_cmd(step, cmd, ANSIBLE, log)
    if rc == 0:
        return True, name + ' ok'
    why = {2: 'a task failed', 4: 'a host was unreachable'}.get(rc, 'exit %d' % rc)
    return False, '%s: %s (see log)' % (name, why)


def step_pyramid(log):
    return playbook('pyramid', 'runPyramidWall.yml', log)


def step_tvs(log):
    return playbook('tvs', 'runTvs.yml', log)


def step_photobooth(log):
    return playbook('photobooth', 'runPhotobooth.yml', log)


RUNNERS = {'audio': step_audio, 'pyramid': step_pyramid, 'tvs': step_tvs, 'photobooth': step_photobooth}


def run_step(step):
    """Run one step; returns True on success. Caller holds run_lock."""
    with lock:
        state['current'] = step
    set_step(step, status='running', started=time.time(), ended=None, message='')
    os.makedirs(LOGS, exist_ok=True)
    with open(log_path(step), 'w') as log:
        log.write('== %s  %s\n' % (time.strftime('%Y-%m-%d %H:%M:%S'), step))
        log.flush()
        try:
            ok, msg = RUNNERS[step](log)
        except Exception as e:  # keep the launcher alive whatever a step does
            ok, msg = False, 'launcher error: %r' % e
        log.write('\n== %s: %s\n' % ('OK' if ok else 'FAILED', msg))
    set_step(step, status='ok' if ok else 'failed', ended=time.time(), message=msg)
    with lock:
        state['current'] = None
    return ok


def run_sequence(steps, mode):
    if not run_lock.acquire(blocking=False):
        return False
    try:
        with lock:
            state['mode'] = mode
            state['last_action'] = {'mode': mode, 'at': time.time()}
            # steps queued in this run show as waiting until their turn
            for s in steps:
                state['steps'][s].update(status='queued', message='')
            save_state()
        for i, s in enumerate(steps):
            if not run_step(s):
                for later in steps[i + 1:]:
                    set_step(later, status='pending', message='not run: %s failed' % s)
                break
    finally:
        with lock:
            state['mode'] = None
            state['current'] = None
        run_lock.release()
    return True


def start_run(steps, mode):
    if run_lock.locked():
        return False
    threading.Thread(target=run_sequence, args=(steps, mode), daemon=True).start()
    return True


# ---------------------------------------------------------------- titlecards

def tvs_hosts():
    """Addresses in the [tvs] group of ansible/config/hosts.ini."""
    hosts, section = [], None
    try:
        with open(HOSTS_INI) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith(('#', ';')):
                    continue
                if line.startswith('['):
                    section = line.strip('[]')
                elif section == 'tvs':
                    hosts.append(line.split()[0])
    except OSError:
        pass
    return hosts


def title_names():
    """The titlecardNames array in tvs/skysets.pde, in order."""
    try:
        with open(TVS_SKETCH) as f:
            m = re.search(r'titlecardNames\s*=\s*\{([^}]*)\}', f.read())
        return re.findall(r'"([^"]*)"', m.group(1)) if m else []
    except OSError:
        return []


def osc_string(addr, text):
    def pad(b):
        return b + b'\0' * (4 - len(b) % 4)
    return pad(addr.encode()) + pad(b',s') + pad(text.encode())


def send_title(name):
    """Sends /tvs/title <name> to every TV laptop. Returns (hosts sent to, errors)."""
    msg = osc_string('/tvs/title', name)
    sent, errors = [], []
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        for h in tvs_hosts():
            try:
                # a few copies: UDP can drop one, and repeats are harmless
                for _ in range(3):
                    sock.sendto(msg, (h, OSC_PORT))
                sent.append(h)
            except OSError as e:
                errors.append('%s: %s' % (h, e))
    with lock:
        state['title'] = {'name': name, 'at': time.time(), 'hosts': sent, 'errors': errors}
        save_state()
    return sent, errors


# ---------------------------------------------------------------- kill all

def kill_everything(log):
    """Stops the show everywhere. Returns (ok, message)."""
    def say(text):
        log.write(text + '\n')
        log.flush()

    say('== %s  kill all' % time.strftime('%Y-%m-%d %H:%M:%S'))
    p = current_proc
    if p is not None and p.poll() is None:
        say('stopping the step that is still running (pid %d)' % p.pid)
        p.terminate()
        try:
            p.wait(timeout=10)
        except subprocess.TimeoutExpired:
            p.kill()

    say('\n-- laptops: killAll.yml (pyramid, TV sketch, photobooth, OSC monitor, NDI)')
    rc = run_cmd('killall', ['ansible-playbook', '-i', 'config/hosts.ini', 'killAll.yml'], ANSIBLE, log)
    # rc 4 = only unreachable hosts (switched off, so nothing runs there): not a failure.
    laptops_ok = rc in (0, 4)
    offline = []
    if rc == 4:
        log.flush()
        with open(log_path('killall')) as f:
            offline = re.findall(r'^(\S+)\s*:.*unreachable=[1-9]', f.read(), re.M)

    say('\n-- this Mac: audio server')
    subprocess.call(['pkill', '-f', 'engine/target/release/audio-server'])
    for _ in range(20):
        if not audio_alive():
            break
        time.sleep(0.25)
    audio_ok = not audio_alive()
    say('audio server stopped' if audio_ok else 'audio server still answering')

    for i in IDS:
        set_step(i, status='pending', started=None, ended=None, message='stopped by Kill all')
    if laptops_ok and audio_ok:
        note = (' (%d laptop%s not reachable, probably off: %s)'
                % (len(offline), '' if len(offline) == 1 else 's', ', '.join(offline))) if offline else ''
        return True, 'everything stopped' + note
    why = []
    if not laptops_ok:
        why.append('killAll.yml: %s' % {2: 'a task failed', 4: 'a host was unreachable'}.get(rc, 'exit %d' % rc))
    if not audio_ok:
        why.append('audio server still running')
    return False, '; '.join(why) + ' (see killall.log)'


def kill_all_then_quit():
    with lock:
        state['killall'] = {'status': 'running', 'message': '', 'at': time.time()}
    os.makedirs(LOGS, exist_ok=True)
    with open(log_path('killall'), 'w') as log:
        ok, msg = kill_everything(log)
        log.write('\n== %s: %s\nclosing the show launcher\n' % ('OK' if ok else 'PROBLEMS', msg))
    with lock:
        state['killall'] = {'status': 'ok' if ok else 'failed', 'message': msg, 'at': time.time()}
    print('kill all: ' + msg + ' - closing the show launcher')
    time.sleep(2.5)            # let the page fetch the result once more
    os._exit(0 if ok else 1)


# ---------------------------------------------------------------- http

def snapshot():
    with lock:
        steps = []
        for meta in STEPS:
            s = dict(state['steps'][meta['id']])
            s.update(meta)
            steps.append(s)
        busy = run_lock.locked()
        nxt = next((m['id'] for m in STEPS if state['steps'][m['id']]['status'] != 'ok'), None)
        return {'steps': steps, 'current': state['current'], 'mode': state['mode'], 'busy': busy,
                'next': nxt, 'audio_alive': audio_alive(), 'audio_ui': AUDIO_UI, 'now': time.time(),
                'titles': title_names(), 'title': state['title'], 'tvs_hosts': tvs_hosts(),
                'killall': state.get('killall')}


def tail(path, max_bytes=60000):
    try:
        with open(path, 'rb') as f:
            f.seek(0, 2)
            size = f.tell()
            f.seek(max(0, size - max_bytes))
            return f.read().decode('utf-8', 'replace')
    except OSError:
        return ''


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass  # keep the terminal quiet; step output is in show/logs/

    def send(self, code, body, ctype='application/json'):
        data = body.encode() if isinstance(body, str) else body
        self.send_response(code)
        self.send_header('Content-Type', ctype)
        self.send_header('Content-Length', str(len(data)))
        self.send_header('Cache-Control', 'no-store')
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        u = urlparse(self.path)
        if u.path in ('/', '/index.html'):
            with open(os.path.join(HERE, 'index.html'), 'rb') as f:
                self.send(200, f.read(), 'text/html; charset=utf-8')
        elif u.path == '/api/state':
            self.send(200, json.dumps(snapshot()))
        elif u.path == '/api/log':
            step = parse_qs(u.query).get('step', [''])[0]
            if step not in IDS + ['audio-server', 'killall']:
                return self.send(404, '{"error":"unknown step"}')
            self.send(200, tail(log_path(step)), 'text/plain; charset=utf-8')
        else:
            self.send(404, '{"error":"not found"}')

    def do_POST(self):
        u = urlparse(self.path)
        q = parse_qs(u.query)
        if u.path == '/api/run_all':
            ok = start_run(list(IDS), 'all')
        elif u.path == '/api/continue':
            nxt = snapshot()['next']
            if nxt is None:
                return self.send(200, json.dumps({'ok': False, 'error': 'every step is already done'}))
            ok = start_run(IDS[IDS.index(nxt):], 'continue')
        elif u.path == '/api/run':
            step = q.get('step', [''])[0]
            if step not in IDS:
                return self.send(404, '{"error":"unknown step"}')
            ok = start_run([step], 'single')
        elif u.path == '/api/kill_all':
            if killing.is_set():
                return self.send(200, json.dumps({'ok': True, 'error': None}))
            killing.set()
            threading.Thread(target=kill_all_then_quit, daemon=True).start()
            return self.send(200, json.dumps({'ok': True, 'error': None}))
        elif u.path == '/api/title':
            name = q.get('name', [''])[0]
            if name != 'OFF' and name not in title_names():
                return self.send(404, '{"error":"unknown titlecard"}')
            sent, errors = send_title(name)
            ok = bool(sent) and not errors
            return self.send(200, json.dumps({'ok': ok, 'sent': sent,
                'error': None if ok else ('; '.join(errors) or 'no [tvs] hosts in hosts.ini')}))
        elif u.path == '/api/reset':
            if run_lock.locked():
                ok = False
            else:
                for i in IDS:
                    set_step(i, status='pending', started=None, ended=None, message='')
                ok = True
        else:
            return self.send(404, '{"error":"not found"}')
        self.send(200, json.dumps({'ok': ok, 'error': None if ok else 'something is already running'}))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--port', type=int, default=8770)
    ap.add_argument('--no-browser', action='store_true')
    ap.add_argument('--kill-all', action='store_true',
                    help='stop the show everywhere and close a running launcher, then exit')
    args = ap.parse_args()
    if args.kill_all:
        return cli_kill_all(args.port)
    os.makedirs(LOGS, exist_ok=True)
    load_state()
    save_state()
    srv = ThreadingHTTPServer(('127.0.0.1', args.port), Handler)
    url = 'http://127.0.0.1:%d' % args.port
    print('show launcher on ' + url + '   (ctrl+c to quit; the show keeps running)')
    if not args.no_browser:
        threading.Timer(0.5, lambda: webbrowser.open(url)).start()
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


def cli_kill_all(port):
    """./show.sh kill: use the running launcher if there is one, else do it here."""
    url = 'http://127.0.0.1:%d' % port
    try:
        urllib.request.urlopen(urllib.request.Request(url + '/api/kill_all', method='POST'), timeout=3).read()
    except OSError:
        print('no show launcher running; stopping everything from here (log: show/logs/killall.log)')
        os.makedirs(LOGS, exist_ok=True)
        with open(log_path('killall'), 'w') as log:
            ok, msg = kill_everything(log)
        print('kill all: ' + msg)
        return 0 if ok else 1
    print('kill all started in the show launcher (log: show/logs/killall.log)')
    last = None
    while True:
        time.sleep(1)
        try:
            st = json.loads(urllib.request.urlopen(url + '/api/state', timeout=3).read())
        except OSError:
            break              # the launcher closed itself: done
        k = st.get('killall') or {}
        last = k
    print('kill all: ' + ((last or {}).get('message') or 'done') + '; show launcher closed')
    return 0 if (last or {}).get('status') != 'failed' else 1


if __name__ == '__main__':
    sys.exit(main())
