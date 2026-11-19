"""Wandering eye: person detection for a busy room.

Runs YOLO11n (models/yolo11n.onnx, in this repo, 320 px) on the CPU with
onnxruntime: no torch, no ultralytics, nothing downloaded at runtime, so it
runs on the small show laptops. A small IoU tracker gives each person an id,
and the eye *chooses* one of them to stare at. It holds that person for a
while, then gets bored and drifts to someone else. Anyone who leaves is
dropped. With nobody around it says so and the sketch drifts back to center.

Talks to the sketch the same way the audio server talks to the pyramid wall:
OSC over UDP, port 9000 (default 127.0.0.1, the sketch on this machine):
    /eye/look ,fff  x y n   x, y = 0..1 in the mirrored camera image, head of
                            the chosen person; n = people in view
    /eye/none ,f    n       nobody chosen

    .venv/bin/python eye_yolo.py                 # camera 0 -> 127.0.0.1:9000
    .venv/bin/python eye_yolo.py --show          # with a debug window
    .venv/bin/python eye_yolo.py --cam 1 --dest 10.10.10.255:9000
"""
import argparse
import os
import random
import socket
import struct
import time

import cv2
import numpy as np
import onnxruntime as ort

HERE = os.path.dirname(os.path.abspath(__file__))
p = argparse.ArgumentParser()
p.add_argument("--cam", type=int, default=0)
p.add_argument("--model", default=os.path.join(HERE, "models", "yolo11n.onnx"))
p.add_argument("--conf", type=float, default=0.4)
p.add_argument("--dest", action="append", help="host:port, repeatable (default 127.0.0.1:9000)")
p.add_argument("--threads", type=int, default=0, help="CPU threads for the model (0 = all)")
p.add_argument("--show", action="store_true")
a = p.parse_args()

# How the eye chooses.
HOLD_MIN, HOLD_MAX = 5.0, 16.0   # seconds it stares at one person before it may switch
SWITCH_CHANCE = 0.6              # when bored, chance it actually moves on (if others are around)
LOST_GRACE = 1.2                 # seconds a chosen person may vanish (occlusion) before it gives up
GLANCE_CHANCE = 0.15             # chance a new arrival steals its attention right away
SMOOTH = 0.3                     # 0..1 per camera frame; lower = steadier, slower
MIN_AREA = 0.004                 # ignore people smaller than this fraction of the frame (far away)
TRACK_IOU = 0.25                 # box overlap that counts as the same person as last frame
TRACK_TTL = 0.8                  # seconds a track survives without a detection

# ---- OSC out --------------------------------------------------------------
def osc(addr, *floats):
    def pad(b):
        return b + b"\0" * (4 - len(b) % 4)
    return pad(addr.encode()) + pad(("," + "f" * len(floats)).encode()) + struct.pack(">" + "f" * len(floats), *floats)

dests = []
for d in a.dest or ["127.0.0.1:9000"]:
    host, port = d.rsplit(":", 1)
    dests.append((host, int(port)))
sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)

def send(pkt):
    for d in dests:
        try:
            sock.sendto(pkt, d)
        except OSError:
            pass

# ---- Model ----------------------------------------------------------------
so = ort.SessionOptions()
if a.threads:
    so.intra_op_num_threads = a.threads
sess = ort.InferenceSession(a.model, so, providers=["CPUExecutionProvider"])
inp = sess.get_inputs()[0]
S = inp.shape[2]   # 320

def detect(frame):
    """People in the frame: list of (x1, y1, x2, y2) in pixels."""
    h, w = frame.shape[:2]
    r = S / max(h, w)
    nw, nh = int(round(w * r)), int(round(h * r))
    px, py = (S - nw) // 2, (S - nh) // 2
    img = np.full((S, S, 3), 114, np.uint8)
    img[py:py + nh, px:px + nw] = cv2.resize(frame, (nw, nh), interpolation=cv2.INTER_LINEAR)
    x = img[:, :, ::-1].transpose(2, 0, 1)[None].astype(np.float32) / 255.0
    out = sess.run(None, {inp.name: x})[0][0]   # (84, N): cx cy w h + 80 class scores
    score = out[4]                               # class 0 = person
    k = score > a.conf
    if not k.any():
        return []
    cx, cy, bw, bh = out[0, k], out[1, k], out[2, k], out[3, k]
    sc = score[k]
    x1 = (cx - bw / 2 - px) / r
    y1 = (cy - bh / 2 - py) / r
    boxes = np.stack([x1, y1, bw / r, bh / r], 1)
    keep = cv2.dnn.NMSBoxes(boxes.tolist(), sc.tolist(), a.conf, 0.5)
    res = []
    for i in np.array(keep).flatten():
        bx, by, bw_, bh_ = boxes[i]
        res.append((max(0, bx), max(0, by), min(w, bx + bw_), min(h, by + bh_)))
    return res

# ---- Tracker: greedy IoU matching, enough to keep ids steady ---------------
def iou(p, q):
    ix = max(0, min(p[2], q[2]) - max(p[0], q[0]))
    iy = max(0, min(p[3], q[3]) - max(p[1], q[1]))
    i = ix * iy
    return i / ((p[2] - p[0]) * (p[3] - p[1]) + (q[2] - q[0]) * (q[3] - q[1]) - i + 1e-6)

tracks = {}   # id -> [box, last_seen]
next_id = 1

def update_tracks(dets, now):
    global next_id
    pairs = sorted(((iou(t[0], d), tid, j) for tid, t in tracks.items() for j, d in enumerate(dets)), reverse=True)
    used_t, used_d = set(), set()
    for v, tid, j in pairs:
        if v < TRACK_IOU:
            break
        if tid in used_t or j in used_d:
            continue
        tracks[tid] = [dets[j], now]
        used_t.add(tid); used_d.add(j)
    for j, d in enumerate(dets):
        if j not in used_d:
            tracks[next_id] = [d, now]
            used_t.add(next_id)
            next_id += 1
    for tid in [t for t, v in tracks.items() if now - v[1] > TRACK_TTL]:
        del tracks[tid]
    return used_t   # ids seen this frame

# ---- Main loop ------------------------------------------------------------
cap = cv2.VideoCapture(a.cam)
cap.set(cv2.CAP_PROP_FRAME_WIDTH, 640)
cap.set(cv2.CAP_PROP_FRAME_HEIGHT, 480)
cap.set(cv2.CAP_PROP_BUFFERSIZE, 1)   # always the newest frame, not a backlog
if not cap.isOpened():
    raise SystemExit(f"could not open camera {a.cam}")
print(f"eye_yolo: {os.path.basename(a.model)} on CPU, sending OSC to " + ", ".join(f"{h}:{p}" for h, p in dests), flush=True)

chosen = None        # track id being watched
chosen_until = 0.0   # when it may get bored
last_seen = 0.0
sx = sy = 0.5        # smoothed point of the chosen person
sm_id = None
known = set()        # ids seen before, to notice new arrivals
fps_t, fps_n = time.time(), 0

def pick(people, exclude=None):
    """Prefer bigger (closer) people, but not always: weighted random."""
    cands = [q for q in people if q[0] != exclude] or people
    return random.choices(cands, weights=[q[3] for q in cands])[0][0]

while True:
    ok, frame = cap.read()
    if not ok:
        time.sleep(0.05)
        continue
    frame = cv2.flip(frame, 1)   # mirror: matches what visitors see
    H, W = frame.shape[:2]
    now = time.time()
    seen = update_tracks(detect(frame), now)

    people = []   # (id, head_x, head_y, area), only those detected this frame
    for tid in seen:
        x1, y1, x2, y2 = tracks[tid][0]
        area = (x2 - x1) * (y2 - y1) / (W * H)
        if area < MIN_AREA:
            continue
        # head: a bit below the top of the box, measured from the box's
        # width (steadier than its height, which jumps when legs leave the frame)
        people.append((tid, (x1 + x2) / 2 / W, (y1 + 0.3 * (x2 - x1)) / H, area))

    ids = {q[0] for q in people}
    new = ids - known
    known |= ids

    if chosen in ids:
        last_seen = now
        if now > chosen_until:                          # bored
            if len(people) > 1 and random.random() < SWITCH_CHANCE:
                chosen = pick(people, exclude=chosen)
            chosen_until = now + random.uniform(HOLD_MIN, HOLD_MAX)
        elif new and random.random() < GLANCE_CHANCE:   # someone walked in
            chosen = random.choice(list(new))
            chosen_until = now + random.uniform(HOLD_MIN, HOLD_MAX)
    elif people and (chosen is None or now - last_seen > LOST_GRACE):
        chosen = pick(people)
        chosen_until = now + random.uniform(HOLD_MIN, HOLD_MAX)
        last_seen = now
    elif not people and now - last_seen > LOST_GRACE:
        chosen = None

    target = next((q for q in people if q[0] == chosen), None)
    if target:
        # smooth the chosen point against box jitter; a new person starts fresh
        # (the sketch's own easing makes the switch a glide)
        if sm_id != chosen:
            sx, sy, sm_id = target[1], target[2], chosen
        sx += (target[1] - sx) * SMOOTH
        sy += (target[2] - sy) * SMOOTH
        send(osc("/eye/look", sx, sy, len(people)))
    else:
        send(osc("/eye/none", len(people)))

    fps_n += 1
    if now - fps_t > 5:
        print(f"eye_yolo: {fps_n / (now - fps_t):.1f} fps, {len(people)} people, watching {chosen}", flush=True)
        fps_t, fps_n = now, 0

    if a.show:
        for tid in seen:
            x1, y1, x2, y2 = map(int, tracks[tid][0])
            c = (0, 0, 255) if tid == chosen else (180, 180, 180)
            cv2.rectangle(frame, (x1, y1), (x2, y2), c, 3 if tid == chosen else 1)
            cv2.putText(frame, str(tid), (x1, y1 - 4), cv2.FONT_HERSHEY_SIMPLEX, 0.6, c, 2)
        cv2.imshow("eye_yolo", frame)
        if cv2.waitKey(1) == 27:
            break
