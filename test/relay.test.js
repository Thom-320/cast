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
function screen(c, { start = 0, total = 10, projector = false } = {}) {
  const s = { i: start, principal: false, ws: null };
  s.ws = new WebSocket(url(c, "type=presentation" + (projector ? "&rol=proyector" : "")));
  const report = () => s.principal && s.ws.send(JSON.stringify({ type: "state", indexh: s.i, indexv: 0, total }));
  s.ws.on("message", (d) => {
    const m = JSON.parse(d);
    if (m.type === "rol") {
      s.principal = m.principal;
      if (m.principal && m.state) s.i = m.state.indexh;
      report();
    } else if (m.type === "state" && !s.principal) {
      s.i = m.indexh;
    } else if (m.type === "cmd" && s.principal) {
      if (m.action === "next") s.i = Math.min(total - 1, s.i + 1);
      if (m.action === "prev") s.i = Math.max(0, s.i - 1);
      if (m.action === "goto") s.i = m.indexh;
      report();
    }
  });
  s.ready = new Promise((r) => s.ws.once("open", r));
  return s;
}

function remote(c, query = "type=controller") {
  const r = { seen: [], acks: [], presence: [], hb: 0 };
  r.ws = new WebSocket(url(c, query));
  r.ws.on("message", (d) => {
    const m = JSON.parse(d);
    if (m.type === "state") r.seen.push(m.indexh);
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
  assert.deepEqual(r.seen, [4, 5, 6, 7, 8, 9], "the phone never jumps backwards");
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
