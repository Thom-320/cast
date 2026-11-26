// Cast relay: one port for everything.
//
//   - WebSocket at /ws/ (also / for old clients):
//       ?cast_code=CODE&type=presentation|controller[&rol=proyector][&quien=NAME]
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
//   - Commands carry an id; the relay drops repeats (double taps, retries after
//     a reconnect) and answers {type:"ack", id, delivered}.
//   - Heartbeat: a WebSocket ping and an app-level {type:"hb"} every 20 s.
//     Proxies such as Cloudflare drop idle sockets at ~100 s, and browsers can
//     only notice a dead link if they stop hearing app messages.
//   - The last state of each room is saved to disk, so a restart does not send
//     the remotes back to slide 1.
//
// Protocol (old messages still work):
//   remote -> {type:"cmd", action:"next"|"prev"|"goto", indexh?, indexv?, id?}
//   presentation -> {type:"state", indexh, indexv, indexf?, total}
//   relay -> state | {type:"rol", principal} | {type:"presence", ...} | ack | hb

const http = require("http");
const fs = require("fs");
const path = require("path");
const WebSocket = require("ws");

const PORT = Number(process.env.RELAY_PORT || process.env.PORT || 8080);
const HOST = process.env.RELAY_HOST || "0.0.0.0";
const GLEAM_URL = new URL(process.env.GLEAM_URL || "http://127.0.0.1:6767");
const STATE_FILE = process.env.CAST_STATE_FILE || path.join(__dirname, "relay-state.json");
const HEARTBEAT_MS = Number(process.env.HEARTBEAT_MS || 20000);
const ROOM_TTL_MS = 12 * 60 * 60 * 1000;
const CODE = /^[A-Za-z0-9_-]{1,32}$/;
const MAX_PER_SECOND = 40;

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

let saveTimer = null;
function saveSoon() {
  clearTimeout(saveTimer);
  saveTimer = setTimeout(() => {
    const out = {};
    for (const [code, r] of rooms) if (r.state) out[code] = r.state;
    fs.writeFile(STATE_FILE + ".tmp", JSON.stringify(out), (err) => {
      if (!err) fs.rename(STATE_FILE + ".tmp", STATE_FILE, () => {});
    });
  }, 500);
}

// ---------------------------------------------------------------- rooms

function room(code) {
  let r = rooms.get(code);
  if (!r) {
    r = { presentations: new Set(), controllers: new Set(), principal: null, state: null, seen: new Map(), used: Date.now() };
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
  if (changed) for (const ws of r.presentations) send(ws, rolMessage(r, ws));
  return changed;
}

function rolMessage(r, ws) {
  return ws === r.principal ? { type: "rol", principal: true, state: r.state } : { type: "rol", principal: false };
}

function presence(r) {
  const p = r.principal;
  const msg = JSON.stringify({
    type: "presence",
    projector: p ? (p.meta.projector ? "explicit" : "implicit") : "none",
    presentations: r.presentations.size,
    controllers: [...r.controllers].map((ws) => ws.meta.who || "?"),
  });
  for (const ws of r.controllers) send(ws, msg);
}

function broadcastState(r, exclude) {
  const msg = JSON.stringify({ type: "state", ...r.state });
  for (const ws of r.presentations) if (ws !== exclude) send(ws, msg);
  for (const ws of r.controllers) send(ws, msg);
}

// Returns false if this command id was already handled.
function firstTime(r, id) {
  if (!id) return true;
  if (r.seen.has(id)) return false;
  r.seen.set(id, Date.now());
  if (r.seen.size > 500) for (const k of [...r.seen.keys()].slice(0, 250)) r.seen.delete(k);
  return true;
}

function cleanState(m, prev) {
  const int = (v, d) => (Number.isInteger(v) && v >= 0 && v < 100000 ? v : d);
  return {
    indexh: int(m.indexh, 0),
    indexv: int(m.indexv, 0),
    indexf: Number.isInteger(m.indexf) ? m.indexf : -1,
    total: int(m.total, prev ? prev.total : 0),
    version: (prev ? prev.version : 0) + 1,
    at: Date.now(),
  };
}

// ---------------------------------------------------------------- server

const server = http.createServer((req, res) => {
  if (req.url === "/relay/health") {
    res.writeHead(200, { "content-type": "application/json" });
    res.end(JSON.stringify({ ok: true, rooms: rooms.size }));
    return;
  }
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

const wss = new WebSocket.Server({ noServer: true, maxPayload: 16 * 1024, perMessageDeflate: false });

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
    if (r.state && ws !== r.principal) send(ws, { type: "state", ...r.state });
  } else {
    r.controllers.add(ws);
    if (r.state) send(ws, { type: "state", ...r.state });
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
      r.state = cleanState(m, r.state);
      broadcastState(r, ws);
      saveSoon();
    } else if (kind === "controller" && m.type === "cmd") {
      const id = typeof m.id === "string" ? m.id.slice(0, 64) : null;
      if (!["next", "prev", "goto"].includes(m.action)) return;
      if (!firstTime(r, id)) {
        if (id) send(ws, { type: "ack", id, delivered: true, duplicate: true });
        return;
      }
      const target = r.principal && isOpen(r.principal) ? r.principal : null;
      if (target) {
        const cmd = { type: "cmd", action: m.action, by: ws.meta.who || undefined };
        if (m.action === "goto") {
          cmd.indexh = Number.isInteger(m.indexh) ? m.indexh : 0;
          cmd.indexv = Number.isInteger(m.indexv) ? m.indexv : 0;
        }
        send(target, cmd);
      }
      if (id) send(ws, { type: "ack", id, delivered: !!target });
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
    if (!r.presentations.size && !r.controllers.size && now - r.used > ROOM_TTL_MS) rooms.delete(code);
  }
}, HEARTBEAT_MS).unref();

loadState();

if (require.main === module) {
  server.listen(PORT, HOST, () => {
    console.log(`cast relay on http://${HOST}:${PORT} (ws at /ws/, HTTP proxied to ${GLEAM_URL.origin})`);
  });
  process.on("SIGINT", () => {
    clearTimeout(saveTimer);
    const out = {};
    for (const [code, r] of rooms) if (r.state) out[code] = r.state;
    try {
      fs.writeFileSync(STATE_FILE, JSON.stringify(out));
    } catch {}
    process.exit(0);
  });
}

module.exports = { server, rooms };
