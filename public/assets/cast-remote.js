// Connects a Reveal.js deck to the cast relay so phones can drive it.
// Usage: <script src="/assets/cast-remote.js" data-cast-code="CODE"
//                [data-ws-url="wss://host/ws/"]></script>
// placed after Reveal is loaded.
//
// Open the deck with ?proyector=1 on the screen everyone watches: that window is
// the one the remotes drive. Any other window with the same code just follows it.
(function () {
  const script = document.currentScript;
  const castCode = script.dataset.castCode;
  const params = new URLSearchParams(location.search);
  const wantsProjector = ["1", "true", "si", "yes"].includes(
    (params.get("proyector") || params.get("projector") || "").toLowerCase(),
  );

  function relayBase() {
    if (script.dataset.wsUrl) return script.dataset.wsUrl.replace(/\?.*$/, "");
    const proto = location.protocol === "https:" ? "wss://" : "ws://";
    // Served straight from the Gleam port: the relay listens next to it on 8080.
    const host = location.port === "6767" ? location.hostname + ":8080" : location.host;
    return proto + host + "/ws/";
  }
  const WS_URL =
    relayBase() +
    "?cast_code=" + encodeURIComponent(castCode) +
    "&type=presentation" +
    (wantsProjector ? "&rol=proyector" : "");

  const style = document.createElement("style");
  style.textContent = `
    .cast-status {
      position: fixed; top: 16px; right: 16px; z-index: 9999;
      display: flex; align-items: center; gap: 8px;
      padding: 8px 16px; border-radius: 0;
      background: #1b3331; color: #f2efe6;
      font: 12px/16px "Space Mono", ui-monospace, "Courier New", monospace;
      letter-spacing: 0.08em;
      transition: opacity 0.3s ease;
    }
    .cast-status__dot {
      width: 8px; height: 8px; border-radius: 999px;
      border: 1px solid #f2efe6;
    }
    .cast-status.connected .cast-status__dot { background: #09aea1; border-color: #09aea1; }
    .cast-status.disconnected .cast-status__dot { background: #f5505d; border-color: #f5505d; }
    .cast-status.connecting .cast-status__dot { animation: cast-blink 1s steps(2, start) infinite; }
    .cast-status.hidden { opacity: 0; pointer-events: none; }
    @keyframes cast-blink { to { visibility: hidden; } }
  `;
  document.head.appendChild(style);

  const statusEl = document.createElement("div");
  statusEl.innerHTML =
    '<span class="cast-status__dot"></span><span class="cast-status__text"></span>';
  document.body.appendChild(statusEl);

  let socket = null;
  let principal = false;
  let applying = false; // true while we move Reveal because the relay told us to
  let lastHeard = 0;
  let retry = 0;
  let hideTimeout = null;

  function status(kind, text) {
    clearTimeout(hideTimeout);
    statusEl.className = "cast-status " + kind;
    statusEl.querySelector(".cast-status__text").textContent = text;
    if (kind === "connected") {
      hideTimeout = setTimeout(() => statusEl.classList.add("hidden"), 3000);
    }
  }
  function connectedLabel() {
    return principal ? "Remote active · projector" : "Following the projector";
  }

  function send(msg) {
    if (socket && socket.readyState === WebSocket.OPEN) socket.send(JSON.stringify(msg));
  }

  function reportState() {
    if (!principal || applying) return;
    const i = Reveal.getIndices();
    send({
      type: "state",
      indexh: i.h,
      indexv: i.v || 0,
      indexf: typeof i.f === "number" ? i.f : -1,
      total: Reveal.getTotalSlides(),
    });
  }

  function goTo(s) {
    if (!s || typeof s.indexh !== "number") return;
    const i = Reveal.getIndices();
    const f = typeof s.indexf === "number" && s.indexf >= 0 ? s.indexf : undefined;
    if (i.h === s.indexh && (i.v || 0) === (s.indexv || 0) && (f === undefined || i.f === f)) return;
    applying = true;
    try {
      Reveal.slide(s.indexh, s.indexv || 0, f);
    } finally {
      applying = false;
    }
  }

  function onMessage(event) {
    lastHeard = Date.now();
    let data;
    try {
      data = JSON.parse(event.data);
    } catch {
      return;
    }
    if (data.type === "rol") {
      principal = !!data.principal;
      // A new principal resumes where the room was, then reports from there.
      if (principal && data.state) goTo(data.state);
      if (principal) reportState();
      status("connected", connectedLabel());
    } else if (data.type === "state") {
      if (!principal) goTo(data); // followers mirror the projector
    } else if (data.type === "cmd" && principal) {
      if (data.action === "next") Reveal.next();
      else if (data.action === "prev") Reveal.prev();
      else if (data.action === "goto") Reveal.slide(data.indexh || 0, data.indexv || 0);
      reportState(); // also covers commands that did not move (first/last slide)
    }
  }

  function connect() {
    status("connecting", "Connecting to remote");
    const ws = new WebSocket(WS_URL);
    socket = ws;
    ws.onopen = () => {
      retry = 0;
      lastHeard = Date.now();
    };
    ws.onmessage = onMessage;
    ws.onclose = () => {
      if (socket !== ws) return;
      principal = false;
      status("disconnected", "Remote lost, retrying");
      // 1 s, 2 s, 4 s ... up to 10 s, with jitter so many tabs do not retry at once.
      const wait = Math.min(10000, 1000 * 2 ** retry++) * (0.75 + Math.random() / 2);
      setTimeout(connect, wait);
    };
    ws.onerror = () => {};
  }

  // The relay speaks every 20 s; silence for 45 s means a dead link.
  setInterval(() => {
    if (socket && socket.readyState === WebSocket.OPEN && Date.now() - lastHeard > 45000) {
      socket.close();
    }
  }, 5000);
  // Phones and laptops suspend tabs: check the link as soon as we are visible.
  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "visible") send({ type: "hb" });
  });

  function start() {
    Reveal.on("slidechanged", reportState);
    Reveal.on("fragmentshown", reportState);
    Reveal.on("fragmenthidden", reportState);
    connect();
  }

  if (Reveal.isReady()) start();
  else Reveal.on("ready", start);
})();
