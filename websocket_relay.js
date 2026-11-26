// Cast relay: one port for everything.
//
//   - WebSocket at /ws/ (also / for old clients):
//       ?cast_code=CODE&type=presentation|controller[&rol=proyector][&quien=NAME]
//   - HTTP fallback for networks that block WebSockets:
//       GET  /relay/room/CODE?since=VERSION[&type=controller][&ov=OUTLINE_VERSION]
//            long poll: answers at once if the room moved past VERSION, else
//            waits up to 25 s for the next change.
//       POST /relay/room/CODE/cmd   body {action, id, indexh?, indexv?} -> ack
//   - Any other HTTP request is proxied to the Gleam server (GLEAM_URL), so a
//     single port (and a single tunnel or reverse-proxy rule) serves the whole app.
//
// Sync model (why the old relay drifted):
//   - The relay owns the slide state of each room. Exactly one presentation is
//     the PRINCIPAL (the projector): remotes' commands go only to it, and only its
//     state counts. Every other screen and every remote follows that absolute
//     state, so stale tabs can no longer drag the room around.
//   - The principal is the newest presentation that joined with rol=proyector;
//     if none did, the oldest connected presentation (implicit principal).
//   - Low latency: the principal reports, with each state, where next and prev
//     would land. On a command the relay sends that predicted state to every
//     follower and remote at once, in parallel with the command to the
//     principal, instead of waiting for the principal's round trip. The
//     principal's report then confirms or corrects it.
//   - Commands carry an id; the relay drops repeats (double taps, retries after
//     a reconnect) and answers {type:"ack", id, delivered}.
//   - Heartbeat: a WebSocket ping and an app-level {type:"hb"} every 20 s.
//   - The last state of each room is saved to disk, so a restart does not send
//     the remotes back to slide 1.
//   - The principal also sends an outline (title and speaker notes per slide).
//     It goes to remotes only, never to other screens: notes are for the
//     presenter's teleprompter.
//
// Protocol (old messages still work):
//   remote -> {type:"cmd", action:"next"|"prev"|"goto", indexh?, indexv?, id?}
//   presentation -> {type:"state", indexh, indexv, indexf?, total, next?, prev?}
//                   {type:"outline", slides:[{h, v, title, notes}]}
//   relay -> state (predicted:true when not yet confirmed) | outline (remotes)
//            | {type:"rol", principal, state?} | presence | ack | hb

const http = require("http");
const fs = require("fs");
const path = require("path");
const WebSocket = require("ws");

const PORT = Number(process.env.RELAY_PORT || process.env.PORT || 8080);
const HOST = process.env.RELAY_HOST || "0.0.0.0";
const GLEAM_URL = new URL(process.env.GLEAM_URL || "http://127.0.0.1:6767");
const STATE_FILE = process.env.CAST_STATE_FILE || path.join(__dirname, "relay-state.json");
const HEARTBEAT_MS = Number(process.env.HEARTBEAT_MS || 20000);
const LONG_POLL_MS = Number(process.env.LONG_POLL_MS || 25000);
const ROOM_TTL_MS = 12 * 60 * 60 * 1000;
const CODE = /^[A-Za-z0-9_-]{1,32}$/;
const MAX_PER_SECOND = 40;
const MAX_OUTLINE_BYTES = 256 * 1024;

const rooms = new Map();

// ---------------------------------------------------------------- persistence

function loadState() {
  try {
    const saved = JSON.parse(fs.readFileSync(STATE_FILE, "utf8"));
    for (const [code, state] of Object.entries(saved)) {
      if (CODE.test(code) && state && typeof state.indexh === "number") {
        room(code).state = state;
      }
    }
  } catch {
    // No file yet, or unreadable: start empty.
  }
}

function snapshot() {
  const out = {};
  for (const [code, r] of rooms) if (r.state) out[code] = r.state;
  return JSON.stringify(out);
}

let saveTimer = null;
function saveSoon() {
  clearTimeout(saveTimer);
  saveTimer = setTimeout(() => {
    fs.writeFile(STATE_FILE + ".tmp", snapshot(), (err) => {
      if (!err) fs.rename(STATE_FILE + ".tmp", STATE_FILE, () => {});
    });
  }, 500);
}

// ---------------------------------------------------------------- rooms

function room(code) {
  let r = rooms.get(code);
  if (!r) {
    r = {
      presentations: new Set(),
      controllers: new Set(),
      principal: null,
      state: null, // last state, as sent to followers and remotes
      routes: null, // {next, prev} reported by the principal for r.state
      outline: null,
      outlineVersion: 0,
      seen: new Map(),
      waiters: new Set(), // HTTP long polls
      used: Date.now(),
    };
    rooms.set(code, r);
  }
  r.used = Date.now();
  return r;
}

const isOpen = (ws) => ws.readyState === WebSocket.OPEN;
function send(ws, msg) {
  if (isOpen(ws)) ws.send(typeof msg === "string" ? msg : JSON.stringify(msg));
}

// Explicit projector (newest wins), otherwise the oldest presentation.
function pickPrincipal(r) {
  let best = null;
  for (const ws of r.presentations) {
    if (!isOpen(ws)) continue;
    if (!best) best = ws;
    else if (ws.meta.projector && (!best.meta.projector || ws.meta.joined > best.meta.joined)) best = ws;
    else if (!ws.meta.projector && !best.meta.projector && ws.meta.joined < best.meta.joined) best = ws;
  }
  const changed = best !== r.principal;
  r.principal = best;
  // A new principal first moves to where the room already is (a reload or a
  // stale tab must not send everyone back to slide 1), then reports from there.
  if (changed) {
    r.routes = null;
    for (const ws of r.presentations) send(ws, rolMessage(r, ws));
  }
  return changed;
}

function rolMessage(r, ws) {
  return ws === r.principal ? { type: "rol", principal: true, state: r.state } : { type: "rol", principal: false };
}

function presenceObj(r) {
  const p = r.principal;
  return {
    type: "presence",
    projector: p ? (p.meta.projector ? "explicit" : "implicit") : "none",
    presentations: r.presentations.size,
    controllers: [...r.controllers].map((ws) => ws.meta.who || "?"),
  };
}
function presence(r) {
  const msg = JSON.stringify(presenceObj(r));
  for (const ws of r.controllers) send(ws, msg);
  wakeWaiters(r);
}

function stateMessage(r) {
  return { type: "state", ...r.state };
}

function broadcastState(r, exclude) {
  const msg = JSON.stringify(stateMessage(r));
  for (const ws of r.presentations) if (ws !== exclude) send(ws, msg);
  for (const ws of r.controllers) send(ws, msg);
  wakeWaiters(r);
}

// Returns false if this command id was already handled.
function firstTime(r, id) {
  if (!id) return true;
  if (r.seen.has(id)) return false;
  r.seen.set(id, Date.now());
  if (r.seen.size > 500) for (const k of [...r.seen.keys()].slice(0, 250)) r.seen.delete(k);
  return true;
}

const int = (v, d) => (Number.isInteger(v) && v >= 0 && v < 100000 ? v : d);
const frag = (v) => (Number.isInteger(v) && v >= -1 && v < 1000 ? v : -1);

function cleanPos(p) {
  if (!p || typeof p !== "object" || !Number.isInteger(p.indexh)) return null;
  return { indexh: int(p.indexh, 0), indexv: int(p.indexv, 0), indexf: frag(p.indexf) };
}

function setState(r, pos, extra) {
  const prev = r.state;
  r.state = {
    indexh: pos.indexh,
    indexv: pos.indexv,
    indexf: pos.indexf,
    total: extra.total !== undefined ? extra.total : prev ? prev.total : 0,
    version: (prev ? prev.version : 0) + 1,
    at: Date.now(),
  };
  if (extra.predicted) r.state.predicted = true;
  saveSoon();
}

function cleanOutline(m) {
  if (!Array.isArray(m.slides)) return null;
  const str = (s, n) => (typeof s === "string" ? s.slice(0, n) : "");
  const slides = m.slides.slice(0, 1000).map((s) => ({
    h: int(s && s.h, 0),
    v: int(s && s.v, 0),
    title: str(s && s.title, 160),
    notes: str(s && s.notes, 8000),
  }));
  return JSON.stringify(slides).length > MAX_OUTLINE_BYTES ? null : slides;
}

// One command from a remote (WebSocket or HTTP). Returns the ack.
function handleCmd(r, m, who) {
  const id = typeof m.id === "string" ? m.id.slice(0, 64) : null;
  if (!["next", "prev", "goto"].includes(m.action)) return null;
  if (!firstTime(r, id)) return { type: "ack", id, delivered: true, duplicate: true };
  const target = r.principal && isOpen(r.principal) ? r.principal : null;
  if (target) {
    const cmd = { type: "cmd", action: m.action, by: who || undefined };
    let predicted = null;
    if (m.action === "goto") {
      cmd.indexh = int(m.indexh, 0);
      cmd.indexv = int(m.indexv, 0);
      predicted = { indexh: cmd.indexh, indexv: cmd.indexv, indexf: -1 };
    } else if (r.routes) {
      predicted = r.routes[m.action];
    }
    send(target, cmd);
    // Everyone else moves now; the principal's report confirms or corrects.
    // Routes are spent: a second tap before the report is only forwarded.
    r.routes = null;
    if (predicted) {
      setState(r, predicted, { predicted: true });
      broadcastState(r, target);
    }
  }
  return { type: "ack", id, delivered: !!target };
}

// ---------------------------------------------------------------- HTTP fallback

function wakeWaiters(r) {
  for (const w of r.waiters) w.check();
}

function json(res, status, body) {
  res.writeHead(status, {
    "content-type": "application/json",
    "cache-control": "no-store",
    "access-control-allow-origin": "*",
  });
  res.end(JSON.stringify(body));
}

function pollRoom(req, res, code, url) {
  const r = room(code);
  const since = Number(url.searchParams.get("since") || 0);
  const ov = Number(url.searchParams.get("ov") || 0);
  const controller = url.searchParams.get("type") === "controller";
  const reply = () => {
    const body = { state: r.state, presence: presenceObj(r) };
    if (controller && r.outline && ov !== r.outlineVersion) {
      body.outline = { slides: r.outline, version: r.outlineVersion };
    }
    json(res, 200, body);
  };
  const changed = () =>
    (r.state && r.state.version !== since) || (controller && r.outline && ov !== r.outlineVersion);
  if (changed()) return reply();
  const w = {
    check() {
      if (!changed()) return;
      done();
      reply();
    },
  };
  const timer = setTimeout(() => {
    done();
    reply();
  }, LONG_POLL_MS);
  const done = () => {
    clearTimeout(timer);
    r.waiters.delete(w);
  };
  r.waiters.add(w);
  req.on("close", done);
}

const httpCount = new Map(); // remote address -> {start, count}
function httpLimited(req) {
  const key = req.socket.remoteAddress || "?";
  const now = Date.now();
  let c = httpCount.get(key);
  if (!c || now - c.start > 1000) httpCount.set(key, (c = { start: now, count: 0 }));
  return ++c.count > MAX_PER_SECOND;
}

function postCmd(req, res, code) {
  let body = "";
  req.on("data", (d) => {
    body += d;
    if (body.length > 4096) req.destroy();
  });
  req.on("end", () => {
    let m;
    try {
      m = JSON.parse(body);
    } catch {
      return json(res, 400, { error: "bad json" });
    }
    if (!m || typeof m !== "object") return json(res, 400, { error: "bad json" });
    const who = typeof m.quien === "string" ? m.quien.slice(0, 24) : "";
    const ack = handleCmd(room(code), m, who);
    if (!ack) return json(res, 400, { error: "unknown action" });
    json(res, 200, ack);
  });
}

function handleRelayHttp(req, res, url) {
  if (url.pathname === "/relay/health") return json(res, 200, { ok: true, rooms: rooms.size });
  const m = url.pathname.match(/^\/relay\/room\/([^/]+)(\/cmd)?$/);
  if (!m) return json(res, 404, { error: "not found" });
  const code = decodeURIComponent(m[1]);
  if (!CODE.test(code)) return json(res, 400, { error: "bad cast code" });
  if (req.method === "OPTIONS") {
    res.writeHead(204, {
      "access-control-allow-origin": "*",
      "access-control-allow-methods": "GET, POST",
      "access-control-allow-headers": "content-type",
    });
    return res.end();
  }
  if (httpLimited(req)) return json(res, 429, { error: "slow down" });
  if (m[2] && req.method === "POST") return postCmd(req, res, code);
  if (!m[2] && req.method === "GET") return pollRoom(req, res, code, url);
  json(res, 405, { error: "method not allowed" });
}

// ---------------------------------------------------------------- server

const server = http.createServer((req, res) => {
  let url;
  try {
    url = new URL(req.url, "http://relay");
  } catch {
    res.writeHead(400);
    return res.end();
  }
  if (url.pathname.startsWith("/relay/")) return handleRelayHttp(req, res, url);
  // Everything else goes to the Gleam server.
  const headers = { ...req.headers };
  headers["x-forwarded-host"] = headers["x-forwarded-host"] || req.headers.host || "";
  headers["x-forwarded-proto"] = headers["x-forwarded-proto"] || (req.socket.encrypted ? "https" : "http");
  const upstream = http.request(
    { hostname: GLEAM_URL.hostname, port: GLEAM_URL.port || 80, method: req.method, path: req.url, headers },
    (up) => {
      res.writeHead(up.statusCode || 502, up.headers);
      up.pipe(res);
    },
  );
  upstream.on("error", () => {
    if (!res.headersSent) res.writeHead(502, { "content-type": "text/plain" });
    res.end("cast: the slide server is not running");
  });
  req.pipe(upstream);
});

const wss = new WebSocket.Server({ noServer: true, maxPayload: MAX_OUTLINE_BYTES + 4096, perMessageDeflate: false });

server.on("upgrade", (req, socket, head) => {
  let url;
  try {
    url = new URL(req.url, "http://relay");
  } catch {
    socket.destroy();
    return;
  }
  if (!["/", "/ws", "/ws/"].includes(url.pathname)) {
    socket.destroy();
    return;
  }
  const code = url.searchParams.get("cast_code") || "";
  if (!CODE.test(code)) {
    socket.write("HTTP/1.1 400 Bad Request\r\n\r\n");
    socket.destroy();
    return;
  }
  wss.handleUpgrade(req, socket, head, (ws) => {
    const p = url.searchParams;
    ws.meta = {
      code,
      kind: p.get("type") === "controller" ? "controller" : "presentation",
      projector: p.get("rol") === "proyector" || p.get("rol") === "projector",
      who: (p.get("quien") || p.get("who") || "").replace(/[^\p{L}\p{N} ._-]/gu, "").slice(0, 24),
      joined: process.hrtime.bigint(),
      alive: true,
      windowStart: Date.now(),
      count: 0,
    };
    wss.emit("connection", ws, req);
  });
});

wss.on("connection", (ws) => {
  const r = room(ws.meta.code);
  const kind = ws.meta.kind;
  ws.on("pong", () => (ws.meta.alive = true));

  if (kind === "presentation") {
    r.presentations.add(ws);
    if (!pickPrincipal(r)) send(ws, rolMessage(r, ws));
    // A follower (or a principal that reloaded) starts where the room is.
    if (r.state && ws !== r.principal) send(ws, stateMessage(r));
  } else {
    r.controllers.add(ws);
    if (r.state) send(ws, stateMessage(r));
    if (r.outline) send(ws, { type: "outline", slides: r.outline, version: r.outlineVersion });
  }
  presence(r);

  ws.on("message", (data) => {
    ws.meta.alive = true;
    const now = Date.now();
    if (now - ws.meta.windowStart > 1000) {
      ws.meta.windowStart = now;
      ws.meta.count = 0;
    }
    if (++ws.meta.count > MAX_PER_SECOND) return;

    let m;
    try {
      m = JSON.parse(data);
    } catch {
      return;
    }
    if (!m || typeof m !== "object") return;
    r.used = now;

    if (kind === "presentation" && m.type === "state") {
      if (ws !== r.principal) return; // followers never steer the room
      const pos = cleanPos(m) || { indexh: 0, indexv: 0, indexf: -1 };
      setState(r, pos, { total: int(m.total, r.state ? r.state.total : 0) });
      const next = cleanPos(m.next);
      const prev = cleanPos(m.prev);
      r.routes = next || prev ? { next, prev } : null;
      broadcastState(r, ws);
    } else if (kind === "presentation" && m.type === "outline") {
      if (ws !== r.principal) return;
      const slides = cleanOutline(m);
      if (!slides) return;
      r.outline = slides;
      r.outlineVersion++;
      const msg = JSON.stringify({ type: "outline", slides, version: r.outlineVersion });
      for (const c of r.controllers) send(c, msg);
      wakeWaiters(r);
    } else if (kind === "controller" && m.type === "cmd") {
      const ack = handleCmd(r, m, ws.meta.who);
      if (ack && ack.id) send(ws, ack);
    } else if (m.type === "hb") {
      // client heartbeat: nothing to do, `alive` is already set
    }
  });

  ws.on("close", () => {
    r.presentations.delete(ws);
    r.controllers.delete(ws);
    if (kind === "presentation") pickPrincipal(r);
    presence(r);
  });
  ws.on("error", () => {});
});

// Heartbeat and cleanup.
setInterval(() => {
  for (const ws of wss.clients) {
    if (!ws.meta.alive) {
      ws.terminate();
      continue;
    }
    ws.meta.alive = false;
    try {
      ws.ping();
    } catch {}
    send(ws, '{"type":"hb"}');
  }
  const now = Date.now();
  for (const [code, r] of rooms) {
    if (!r.presentations.size && !r.controllers.size && !r.waiters.size && now - r.used > ROOM_TTL_MS) {
      rooms.delete(code);
    }
  }
  for (const [k, c] of httpCount) if (now - c.start > 5000) httpCount.delete(k);
}, HEARTBEAT_MS).unref();

loadState();

if (require.main === module) {
  server.listen(PORT, HOST, () => {
    console.log(`cast relay on http://${HOST}:${PORT} (ws at /ws/, HTTP proxied to ${GLEAM_URL.origin})`);
  });
  process.on("SIGINT", () => {
    clearTimeout(saveTimer);
    try {
      fs.writeFileSync(STATE_FILE, snapshot());
    } catch {}
    process.exit(0);
  });
}

module.exports = { server, rooms };
