// Relay tests with simulated screens and remotes: node --test test/
// Each simulated screen behaves like public/assets/cast-remote.js.
const { test, before, after } = require("node:test");
const assert = require("node:assert/strict");
const { spawn } = require("node:child_process");
const http = require("node:http");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const WebSocket = require("ws");

const RELAY = path.join(__dirname, "..", "websocket_relay.js");
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "cast-relay-"));
const STATE_FILE = path.join(tmp, "state.json");
let upstream, upstreamPort;
let relay, port;
let n = 0;
const code = () => "t" + ++n + Math.random().toString(36).slice(2, 6);

function freePort() {
  return new Promise((res) => {
    const s = http.createServer().listen(0, "127.0.0.1", () => {
      const p = s.address().port;
      s.close(() => res(p));
    });
  });
}

async function startRelay() {
  port = await freePort();
  relay = spawn(process.execPath, [RELAY], {
    env: {
      ...process.env,
      RELAY_PORT: String(port),
      RELAY_HOST: "127.0.0.1",
      GLEAM_URL: "http://127.0.0.1:" + upstreamPort,
      CAST_STATE_FILE: STATE_FILE,
      HEARTBEAT_MS: "300",
    },
    stdio: ["ignore", "pipe", "inherit"],
  });
  await new Promise((res) => relay.stdout.once("data", res));
}
async function stopRelay(signal = "SIGINT") {
  const done = new Promise((res) => relay.once("exit", res));
  relay.kill(signal);
  await done;
}

function url(c, query) {
  return `ws://127.0.0.1:${port}/ws/?cast_code=${c}&${query}`;
}

// A deck window: mirrors the room when following, obeys commands when principal.
// Like cast-remote.js it reports where next/prev would land; `delay` simulates
// a slow projector (busy laptop, bad wifi).
function screen(c, { start = 0, total = 10, projector = false, delay = 0 } = {}) {
  const s = { i: start, principal: false, ws: null, got: [] };
  s.ws = new WebSocket(url(c, "type=presentation" + (projector ? "&rol=proyector" : "")));
  const pos = (i) => ({ indexh: i, indexv: 0, indexf: -1 });
  const report = () =>
    s.principal &&
    s.ws.send(JSON.stringify({
      type: "state", indexh: s.i, indexv: 0, total,
      next: s.i < total - 1 ? pos(s.i + 1) : null,
      prev: s.i > 0 ? pos(s.i - 1) : null,
    }));
  s.ws.on("message", (d) => {
    const m = JSON.parse(d);
    s.got.push(m);
    if (m.type === "rol") {
      s.principal = m.principal;
      if (m.principal && m.state) s.i = m.state.indexh;
      report();
    } else if (m.type === "state" && !s.principal) {
      s.i = m.indexh;
    } else if (m.type === "cmd" && s.principal) {
      setTimeout(() => {
        if (m.action === "next") s.i = Math.min(total - 1, s.i + 1);
        if (m.action === "prev") s.i = Math.max(0, s.i - 1);
        if (m.action === "goto") s.i = m.indexh;
        report();
      }, delay);
    }
  });
  s.ready = new Promise((r) => s.ws.once("open", r));
  return s;
}

function remote(c, query = "type=controller") {
  const r = { seen: [], states: [], acks: [], presence: [], outlines: [], hb: 0 };
  r.ws = new WebSocket(url(c, query));
  r.ws.on("message", (d) => {
    const m = JSON.parse(d);
    if (m.type === "state") {
      r.seen.push(m.indexh);
      r.states.push({ ...m, t: Date.now() });
    }
    if (m.type === "outline") r.outlines.push(m);
    if (m.type === "ack") r.acks.push(m);
    if (m.type === "presence") r.presence.push(m);
    if (m.type === "hb") r.hb++;
  });
  r.cmd = (action, id, extra = {}) => r.ws.send(JSON.stringify({ type: "cmd", action, id, ...extra }));
  r.ready = new Promise((res) => r.ws.once("open", res));
  return r;
}

before(async () => {
  upstream = http.createServer((req, res) => {
    res.setHeader("content-type", "text/plain");
    res.end(`gleam saw ${req.method} ${req.url} host=${req.headers["x-forwarded-host"]}`);
  });
  await new Promise((r) => upstream.listen(0, "127.0.0.1", r));
  upstreamPort = upstream.address().port;
  await startRelay();
});
after(async () => {
  await stopRelay();
  upstream.close();
});

test("a stale tab no longer drags the room: everyone follows the projector", async () => {
  const c = code();
  const proj = screen(c, { start: 4, projector: true });
  await proj.ready;
  const stale = screen(c, { start: 0 });
  await stale.ready;
  await sleep(100);
  const r = remote(c);
  await r.ready;
  await sleep(100);
  for (let k = 0; k < 5; k++) {
    r.cmd("next", "a" + k);
    await sleep(60);
  }
  await sleep(150);
  assert.equal(proj.i, 9);
  assert.equal(stale.i, 9, "the other window mirrors the projector");
  // predicted and confirmed states repeat a slide, but never go back
  const steps = r.seen.filter((x, k) => x !== r.seen[k - 1]);
  assert.deepEqual(steps, [4, 5, 6, 7, 8, 9], "the phone never jumps backwards");
  for (const x of [proj, stale, r]) x.ws.close();
});

test("a repeated command id (double tap, retry after reconnect) moves once", async () => {
  const c = code();
  const proj = screen(c, { projector: true });
  await proj.ready;
  const r = remote(c);
  await r.ready;
  await sleep(80);
  r.cmd("next", "same");
  r.cmd("next", "same");
  r.cmd("next", "same");
  await sleep(150);
  assert.equal(proj.i, 1);
  assert.equal(r.acks.length, 3);
  assert.equal(r.acks.filter((a) => a.duplicate).length, 2);
  proj.ws.close();
  r.ws.close();
});

test("with no screen connected the remote is told the command went nowhere", async () => {
  const c = code();
  const r = remote(c);
  await r.ready;
  await sleep(50);
  r.cmd("next", "x1");
  await sleep(100);
  assert.equal(r.acks[0].delivered, false);
  assert.equal(r.presence.at(-1).projector, "none");
  r.ws.close();
});

test("a projector that reloads resumes the room's slide instead of slide 1", async () => {
  const c = code();
  let proj = screen(c, { projector: true });
  await proj.ready;
  const r = remote(c);
  await r.ready;
  await sleep(80);
  r.cmd("goto", "g1", { indexh: 6 });
  await sleep(120);
  assert.equal(proj.i, 6);
  proj.ws.close();
  await sleep(100);
  proj = screen(c, { start: 0, projector: true }); // fresh page, Reveal starts at 0
  await proj.ready;
  await sleep(150);
  assert.equal(proj.i, 6);
  assert.equal(r.seen.at(-1), 6);
  proj.ws.close();
  r.ws.close();
});

test("without an explicit projector the oldest window leads and others follow", async () => {
  const c = code();
  const first = screen(c, { start: 2 });
  await first.ready;
  await sleep(50);
  const second = screen(c, { start: 0 });
  await second.ready;
  await sleep(100);
  assert.equal(first.principal, true);
  assert.equal(second.principal, false);
  assert.equal(second.i, 2);
  // a follower that tries to report a different slide is ignored
  second.ws.send(JSON.stringify({ type: "state", indexh: 0, indexv: 0, total: 10 }));
  const r = remote(c);
  await r.ready;
  await sleep(100);
  assert.equal(r.seen.at(-1), 2);
  // the leader leaves: the remaining window takes over from where the room was
  first.ws.close();
  await sleep(150);
  assert.equal(second.principal, true);
  r.cmd("next", "n1");
  await sleep(120);
  assert.equal(second.i, 3);
  second.ws.close();
  r.ws.close();
});

test("old cast clients still work (path / and commands without id)", async () => {
  const c = code();
  const proj = screen(c, { projector: true });
  await proj.ready;
  const legacy = new WebSocket(`ws://127.0.0.1:${port}/?cast_code=${c}&type=controller`);
  await new Promise((r) => legacy.once("open", r));
  await sleep(60);
  legacy.send(JSON.stringify({ type: "cmd", action: "next" }));
  legacy.send("not json");
  legacy.send(JSON.stringify({ type: "cmd", action: "next" }));
  await sleep(150);
  assert.equal(proj.i, 2);
  proj.ws.close();
  legacy.close();
});

test("heartbeats keep idle links alive", async () => {
  const c = code();
  const r = remote(c);
  await r.ready;
  await sleep(800);
  assert.ok(r.hb >= 2, `got ${r.hb} heartbeats`);
  r.ws.close();
});

test("bad codes are refused and floods are capped", async () => {
  const bad = new WebSocket(`ws://127.0.0.1:${port}/ws/?cast_code=../etc&type=controller`);
  const err = await new Promise((r) => bad.once("error", r));
  assert.match(String(err.message), /400/);

  const c = code();
  const proj = screen(c, { projector: true, total: 1000 });
  await proj.ready;
  const r = remote(c);
  await r.ready;
  await sleep(60);
  for (let k = 0; k < 100; k++) r.cmd("next", "f" + k);
  await sleep(300);
  assert.ok(proj.i <= 40, `moved ${proj.i}`);
  proj.ws.close();
  r.ws.close();
});

test("one port: plain HTTP is proxied to the Gleam server", async () => {
  const body = await new Promise((res, rej) =>
    http.get(`http://127.0.0.1:${port}/join?code=abc`, (r) => {
      let b = "";
      r.on("data", (d) => (b += d));
      r.on("end", () => res(b));
    }).on("error", rej),
  );
  assert.equal(body, `gleam saw GET /join?code=abc host=127.0.0.1:${port}`);
});

test("the room's slide survives a relay restart", async () => {
  const c = code();
  const proj = screen(c, { projector: true });
  await proj.ready;
  const r = remote(c);
  await r.ready;
  await sleep(60);
  r.cmd("goto", "p1", { indexh: 7 });
  await sleep(900); // state is saved to disk shortly after it changes
  proj.ws.close();
  r.ws.close();
  await stopRelay("SIGKILL"); // a crash, not a clean shutdown
  await startRelay();
  const back = remote(c);
  await back.ready;
  await sleep(100);
  assert.equal(back.seen[0], 7);
  back.ws.close();
});

function httpReq(method, path, body) {
  return new Promise((res, rej) => {
    const req = http.request(
      { host: "127.0.0.1", port, method, path, headers: { "content-type": "text/plain" } },
      (r) => {
        let b = "";
        r.on("data", (d) => (b += d));
        r.on("end", () => res({ status: r.statusCode, headers: r.headers, body: b ? JSON.parse(b) : null }));
      },
    );
    req.on("error", rej);
    if (body) req.write(JSON.stringify(body));
    req.end();
  });
}

test("low latency: followers and the phone move before a slow projector answers", async () => {
  const c = code();
  const proj = screen(c, { start: 3, projector: true, delay: 400 });
  await proj.ready;
  const audience = screen(c);
  await audience.ready;
  const r = remote(c);
  await r.ready;
  await sleep(100);
  const t0 = Date.now();
  r.cmd("next", "fast1");
  await sleep(150);
  assert.equal(audience.i, 4, "the audience already shows the next slide");
  const first = r.states.find((s) => s.indexh === 4);
  assert.ok(first && first.predicted, "the phone got the predicted slide");
  assert.ok(first.t - t0 < 150, `predicted after ${first.t - t0} ms`);
  assert.equal(proj.i, 3, "the projector itself has not answered yet");
  await sleep(450);
  assert.equal(proj.i, 4);
  const last = r.states.at(-1);
  assert.equal(last.indexh, 4);
  assert.ok(!last.predicted, "the projector confirmed it");
  for (const x of [proj, audience, r]) x.ws.close();
});

test("a jump from the slide grid moves everyone at once", async () => {
  const c = code();
  const proj = screen(c, { projector: true, delay: 300 });
  await proj.ready;
  const audience = screen(c);
  await audience.ready;
  const r = remote(c);
  await r.ready;
  await sleep(80);
  r.cmd("goto", "j1", { indexh: 8, indexv: 0 });
  await sleep(100);
  assert.equal(audience.i, 8);
  await sleep(350);
  assert.equal(proj.i, 8);
  for (const x of [proj, audience, r]) x.ws.close();
});

test("speaker notes reach the remotes' teleprompter, never the other screens", async () => {
  const c = code();
  const proj = screen(c, { projector: true });
  await proj.ready;
  const audience = screen(c);
  await audience.ready;
  const early = remote(c);
  await early.ready;
  await sleep(60);
  const slides = [
    { h: 0, v: 0, title: "Hola", notes: "Saluda y presenta el tema" },
    { h: 1, v: 0, title: "Datos", notes: "Cita la fuente: DANE 2025" },
  ];
  proj.ws.send(JSON.stringify({ type: "outline", slides }));
  // a follower trying to replace the outline is ignored
  audience.ws.send(JSON.stringify({ type: "outline", slides: [{ h: 0, v: 0, title: "x", notes: "hack" }] }));
  await sleep(100);
  assert.equal(early.outlines.length, 1);
  assert.equal(early.outlines[0].slides[1].notes, "Cita la fuente: DANE 2025");
  const late = remote(c);
  await late.ready;
  await sleep(80);
  assert.equal(late.outlines[0].slides[0].title, "Hola", "a remote that joins later gets it too");
  const leaked = [...proj.got, ...audience.got].some((m) => JSON.stringify(m).includes("DANE"));
  assert.equal(leaked, false, "no screen receives the notes");
  for (const x of [proj, audience, early, late]) x.ws.close();
});

test("HTTP fallback: a phone without WebSockets still follows and controls", async () => {
  const c = code();
  const proj = screen(c, { projector: true, start: 2 });
  await proj.ready;
  await sleep(80);
  proj.ws.send(JSON.stringify({ type: "outline", slides: [{ h: 0, v: 0, title: "A", notes: "n" }] }));
  await sleep(50);

  const first = await httpReq("GET", `/relay/room/${c}?type=controller&since=0&ov=0`);
  assert.equal(first.status, 200);
  assert.equal(first.headers["access-control-allow-origin"], "*");
  assert.equal(first.body.state.indexh, 2);
  assert.equal(first.body.presence.projector, "explicit");
  assert.equal(first.body.outline.slides[0].title, "A");

  // a long poll waits for the next change instead of returning at once
  const since = first.body.state.version;
  const ov = first.body.outline.version;
  const t0 = Date.now();
  const waiting = httpReq("GET", `/relay/room/${c}?type=controller&since=${since}&ov=${ov}`);
  await sleep(200);
  const ack = await httpReq("POST", `/relay/room/${c}/cmd`, { action: "next", id: "h1" });
  assert.deepEqual(ack.body, { type: "ack", id: "h1", delivered: true });
  const woke = await waiting;
  assert.ok(Date.now() - t0 < 1000, "the poll answered as soon as the slide changed");
  assert.equal(woke.body.state.indexh, 3);
  assert.equal(woke.body.outline, undefined, "the outline is not resent when unchanged");

  const dup = await httpReq("POST", `/relay/room/${c}/cmd`, { action: "next", id: "h1" });
  assert.equal(dup.body.duplicate, true);
  await sleep(80);
  assert.equal(proj.i, 3, "the resent command did not move twice");

  assert.equal((await httpReq("GET", `/relay/room/bad%2Fcode?since=0`)).status, 400);
  assert.equal((await httpReq("POST", `/relay/room/${c}/cmd`, { action: "explode" })).status, 400);
  proj.ws.close();
});

test("HTTP fallback: an audience screen long-polls the projector's slide", async () => {
  const c = code();
  const proj = screen(c, { projector: true });
  await proj.ready;
  const r = remote(c);
  await r.ready;
  await sleep(80);
  const v0 = (await httpReq("GET", `/relay/room/${c}?since=0`)).body.state.version;
  const waiting = httpReq("GET", `/relay/room/${c}?since=${v0}`);
  r.cmd("goto", "w1", { indexh: 5 });
  const woke = await waiting;
  assert.equal(woke.body.state.indexh, 5);
  assert.equal(woke.body.outline, undefined, "screens never get the notes");
  proj.ws.close();
  r.ws.close();
});
