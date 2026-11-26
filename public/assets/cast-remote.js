// Connects a Reveal.js deck to the cast relay so phones can drive it.
// Usage: <script src="/assets/cast-remote.js" data-cast-code="CODE"
//                [data-ws-url="wss://host/ws/"]></script>
// placed after Reveal is loaded.
//
// Open the deck with ?proyector=1&k=KEY (the presenter's link) on the screen
// everyone watches: that window is the one the remotes drive. Any window
// without the control key (the audience) just follows it.
// Speaker notes (<aside class="notes">) go to the remote's teleprompter only.
(function () {
  const script = document.currentScript;
  const castCode = script.dataset.castCode;
  const params = new URLSearchParams(location.search);
  const wantsProjector = ["1", "true", "si", "yes"].includes(
    (params.get("proyector") || params.get("projector") || "").toLowerCase(),
  );

  // The key is moved out of the address bar (the projector shows it to the
  // room) into this tab's session, so a reload keeps it.
  const KEY_SLOT = "cast-k-" + castCode;
  let controlKey = params.get("k") || "";
  try {
    if (controlKey) sessionStorage.setItem(KEY_SLOT, controlKey);
    else controlKey = sessionStorage.getItem(KEY_SLOT) || "";
  } catch {
    // no session storage: the key still works until the tab closes
  }
  if (params.has("k")) {
    params.delete("k");
    const rest = params.toString();
    try {
      history.replaceState(history.state, "", location.pathname + (rest ? "?" + rest : "") + location.hash);
    } catch {
      // some embedded viewers forbid it; harmless
    }
  }

  function relayBase() {
    if (script.dataset.wsUrl) return script.dataset.wsUrl.replace(/\?.*$/, "");
    const proto = location.protocol === "https:" ? "wss://" : "ws://";
    // Served straight from the Gleam port: the relay listens next to it on 8080.
    const host = location.port === "6767" ? location.hostname + ":8080" : location.host;
    return proto + host + "/ws/";
  }
  const BASE = relayBase();
  const WS_URL =
    BASE +
    "?cast_code=" + encodeURIComponent(castCode) +
    "&type=presentation" +
    (wantsProjector ? "&rol=proyector" : "") +
    (controlKey ? "&k=" + encodeURIComponent(controlKey) : "");
  // Same host as the WebSocket, plain HTTP: used when WebSockets are blocked.
  const HTTP_URL =
    BASE.replace(/^ws/, "http").replace(/\/ws\/?$|\/$/, "") + "/relay/room/" + encodeURIComponent(castCode);

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
  let failures = 0; // WebSocket attempts in a row that never opened
  let polling = false;
  let lastVersion = 0;
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

  // ------------------------------------------------------------ screen awake
  // A laptop or phone that dims and sleeps also drops the connection.
  let wakeLock = null;
  async function keepAwake() {
    if (!("wakeLock" in navigator) || document.visibilityState !== "visible" || wakeLock) return;
    try {
      wakeLock = await navigator.wakeLock.request("screen");
      wakeLock.addEventListener("release", () => (wakeLock = null));
    } catch {
      wakeLock = null; // not allowed here (no https, battery saver...)
    }
  }

  function send(msg) {
    if (socket && socket.readyState === WebSocket.OPEN) socket.send(JSON.stringify(msg));
  }

  // ------------------------------------------------------------ where next/prev land
  // Mirrors Reveal.next()/prev(): fragment, then down, then right (or back).
  function maxFragment(slide) {
    let max = -1;
    if (!slide) return max;
    for (const el of slide.querySelectorAll(".fragment[data-fragment-index]")) {
      max = Math.max(max, Number(el.getAttribute("data-fragment-index")) || 0);
    }
    return max;
  }
  function routes(i) {
    const f = typeof i.f === "number" ? i.f : -1;
    const frags = Reveal.availableFragments();
    const r = Reveal.availableRoutes();
    let next = null;
    let prev = null;
    if (frags.next) next = { indexh: i.h, indexv: i.v || 0, indexf: f + 1 };
    else if (r.down) next = { indexh: i.h, indexv: (i.v || 0) + 1, indexf: -1 };
    else if (r.right) next = { indexh: i.h + 1, indexv: 0, indexf: -1 };
    if (frags.prev) prev = { indexh: i.h, indexv: i.v || 0, indexf: f - 1 };
    else if (r.up) {
      const above = Reveal.getSlide(i.h, (i.v || 0) - 1);
      prev = { indexh: i.h, indexv: (i.v || 0) - 1, indexf: maxFragment(above) };
    } else if (r.left) {
      const stack = Reveal.getHorizontalSlides()[i.h - 1];
      // Going back into a vertical stack lands on a slide we cannot guess cheaply.
      if (stack && !stack.querySelector("section")) {
        prev = { indexh: i.h - 1, indexv: 0, indexf: maxFragment(stack) };
      }
    }
    return { next, prev };
  }

  function reportState() {
    if (!principal || applying) return;
    const i = Reveal.getIndices();
    const { next, prev } = routes(i);
    send({
      type: "state",
      indexh: i.h,
      indexv: i.v || 0,
      indexf: typeof i.f === "number" ? i.f : -1,
      total: Reveal.getTotalSlides(),
      next,
      prev,
    });
  }

  // ------------------------------------------------------------ teleprompter outline
  function htmlToText(html) {
    if (!html) return "";
    const doc = new DOMParser().parseFromString(
      String(html).replace(/<br\s*\/?>/gi, "\n").replace(/<\/(p|li|div|h\d)>/gi, "\n"),
      "text/html",
    );
    return (doc.body.textContent || "").replace(/\n{3,}/g, "\n\n").trim();
  }
  function noteOf(slide) {
    const aside = slide.querySelector(":scope > aside.notes");
    if (aside) return aside.innerHTML;
    return slide.getAttribute("data-notes") || "";
  }

  // The server leaves speaker notes out of a page asked for without the key.
  // After a reload the key lives in this tab only, so fetch the keyed copy
  // once and read the notes from it, by slide position.
  let fetchedNotes = null; // Map "h.v" -> notes html, or null if not needed
  async function loadNotes() {
    if (!controlKey) return;
    if (document.querySelector(".reveal .slides aside.notes, .reveal .slides [data-notes]")) return;
    try {
      const res = await fetch(location.pathname + "?k=" + encodeURIComponent(controlKey), {
        cache: "no-store",
        credentials: "same-origin",
      });
      if (!res.ok) return;
      const doc = new DOMParser().parseFromString(await res.text(), "text/html");
      const map = new Map();
      doc.querySelectorAll(".reveal .slides > section").forEach((top, h) => {
        const stack = top.querySelectorAll(":scope > section");
        if (stack.length) stack.forEach((sec, v) => map.set(h + "." + v, noteOf(sec)));
        else map.set(h + ".0", noteOf(top));
      });
      fetchedNotes = map;
    } catch {
      // the teleprompter just shows titles
    }
  }
  function notesText(slide, i) {
    let html = Reveal.getSlideNotes(slide);
    if (!html && fetchedNotes) html = fetchedNotes.get(i.h + "." + (i.v || 0));
    return htmlToText(html);
  }
  function outline() {
    return Reveal.getSlides().map((slide) => {
      const i = Reveal.getIndices(slide);
      const heading = slide.querySelector("h1, h2, h3");
      const title = (heading ? heading.textContent : slide.getAttribute("data-title") || "")
        .replace(/\s+/g, " ")
        .trim();
      return { h: i.h, v: i.v || 0, title, notes: notesText(slide, i) };
    });
  }
  function sendOutline() {
    if (!principal) return;
    try {
      send({ type: "outline", slides: outline() });
    } catch {
      // an odd deck must never break the remote
    }
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
      if (principal) {
        reportState();
        sendOutline();
      }
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

  // ------------------------------------------------------------ HTTP fallback
  // Followers keep mirroring the projector through long polls while the
  // WebSocket is down. The projector itself needs the WebSocket.
  async function pollLoop() {
    if (polling) return;
    polling = true;
    while (!(socket && socket.readyState === WebSocket.OPEN)) {
      try {
        const res = await fetch(HTTP_URL + "?since=" + lastVersion, { cache: "no-store" });
        const body = await res.json();
        if (body.state) {
          lastVersion = body.state.version || 0;
          goTo(body.state);
        }
        status("connected", "Following the projector · HTTP");
      } catch {
        await new Promise((r) => setTimeout(r, 2000));
      }
    }
    polling = false;
  }

  function connect() {
    if (!polling) status("connecting", "Connecting to remote");
    const ws = new WebSocket(WS_URL);
    socket = ws;
    let opened = false;
    ws.onopen = () => {
      opened = true;
      retry = 0;
      failures = 0;
      lastHeard = Date.now();
      keepAwake();
    };
    ws.onmessage = onMessage;
    ws.onclose = () => {
      if (socket !== ws) return;
      principal = false;
      if (!opened && ++failures >= 2) pollLoop();
      if (!polling) status("disconnected", "Remote lost, retrying");
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
    if (document.visibilityState !== "visible") return;
    send({ type: "hb" });
    keepAwake();
  });

  function start() {
    Reveal.on("slidechanged", reportState);
    Reveal.on("fragmentshown", reportState);
    Reveal.on("fragmenthidden", reportState);
    connect();
    // Resend the teleprompter once notes come from the keyed copy.
    loadNotes().then(() => fetchedNotes && sendOutline());
  }

  if (Reveal.isReady()) start();
  else Reveal.on("ready", start);
})();
