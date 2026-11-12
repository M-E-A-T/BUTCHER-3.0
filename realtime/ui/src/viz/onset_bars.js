// Per-band onset state, drawn under the L/M/H bars with the same column
// geometry. Each band is either "–" (idle, empty track) or "1" (onset: the
// track fills with the band color). An onset is a single-block pulse on the
// wire, so it's held for ONSET_HOLD_S to be visible.

import { store, recordVizPerf } from "../store.js";
import { LMH_HEX, LMH_ORDER, theme } from "../colors.js";
import { makeSurface, makeLayer, FONT_UI, FONT_MONO } from "./surface.js";

const TRACK = "#1a1d22";
const ONSET_HOLD_S = 0.12;

export function makeOnsetBars(canvas) {
  const ctx = canvas.getContext("2d", { alpha: false });
  const surf = makeSurface(canvas);
  const layer = makeLayer();
  const g0 = { padX: 0, padTop: 0, slotW: 0, barW: 0, trackH: 0 };

  function geometry(w, h, dpr) {
    // Same horizontal layout as lmh_bars.js so the columns line up.
    const padBot = 16 * dpr;
    g0.padX = 16 * dpr;
    g0.padTop = 8 * dpr;
    g0.slotW = (w - 2 * g0.padX) / 3;
    g0.barW = Math.min(g0.slotW * 0.6, 120 * dpr);
    g0.trackH = Math.max(1, h - g0.padTop - padBot);
  }

  function buildStatic(w, h, dpr) {
    const c = layer.canvas, g = layer.ctx;
    c.width = w; c.height = h;
    g.fillStyle = theme.bg;
    g.fillRect(0, 0, w, h);
    g.font = `${Math.round(10 * dpr)}px ${FONT_UI}`;
    g.textAlign = "center";
    g.textBaseline = "alphabetic";
    for (let i = 0; i < 3; i++) {
      const x = g0.padX + g0.slotW * i + (g0.slotW - g0.barW) / 2;
      g.fillStyle = TRACK;
      g.fillRect(x, g0.padTop, g0.barW, g0.trackH);
      g.fillStyle = "#8b939c";
      g.fillText(`${LMH_ORDER[i]} onset`, x + g0.barW / 2, h - 3 * dpr);
    }
  }

  function draw() {
    const t0 = performance.now();
    const { w, h, dpr, version } = surf.fit();
    geometry(w, h, dpr);
    const key = version * 1024 + theme.version;
    if (layer.key !== key) { layer.key = key; buildStatic(w, h, dpr); }
    ctx.drawImage(layer.canvas, 0, 0);

    const now = performance.now();
    const ts = [store.low_onset_pulse_t, store.mid_onset_pulse_t, store.high_onset_pulse_t];
    const fontPx = Math.round(Math.max(12 * dpr, Math.min(g0.trackH * 0.6, 40 * dpr)));
    ctx.font = `bold ${fontPx}px ${FONT_MONO}`;
    ctx.textAlign = "center";
    ctx.textBaseline = "middle";
    const cy = g0.padTop + g0.trackH / 2;
    for (let i = 0; i < 3; i++) {
      const x = g0.padX + g0.slotW * i + (g0.slotW - g0.barW) / 2;
      const since = (now - (ts[i] || -1e9)) / 1000;
      const on = since >= 0 && since < ONSET_HOLD_S;
      if (on) {
        ctx.fillStyle = LMH_HEX[i];
        ctx.fillRect(x, g0.padTop, g0.barW, g0.trackH);
      }
      ctx.fillStyle = on ? "#fff" : "#5c636b";
      ctx.fillText(on ? "1" : "–", x + g0.barW / 2, cy);
    }
    recordVizPerf("onsets", performance.now() - t0);
  }

  return { draw };
}
