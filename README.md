# REALLY IMPORTANT NOTE 

Ai wrote this readme, i apologize, i did read and removed the wrong and cringey things but still, this is written by ai
The UI is vibe coded, i apolozize, i do not wanna touch javascript with a 10 foot pole.

# Cast - Remote Presentation Control System


A self-hosted application that allows you to upload presentations (PDF/PPTX), convert them to web slides, and control them remotely from any device.


## Features

- 📤 Upload PDF or PPTX presentations
- 🔄 Automatic conversion to web slides
- 🎛️ Remote control via mobile device
- 📱 QR code for quick connection
- 🔌 Real-time WebSocket communication
- 📊 Slide state synchronization

## Quick Start with Nix

```bash
# Clone and enter the environment
git clone <repository-url>
cd cast
nix run .

# Only if the relay lives on another host
WEBSOCKET_URL='wss://your-domain/ws/' nix run .
```

## Manual Setup

### Prerequisites

- Gleam (>= 1.3.0)
- Node.js (>= 18)
- poppler-utils (pdftoppm)
- LibreOffice (headless)
- pngquant
- qrrs
### Installation

```bash
# Install dependencies
npm install

# Build static assets
./setup.sh

# Build Gleam application
gleam build
```

### Running

```bash
# Gleam server (port 6767, internal)
gleam run &

# Relay: WebSocket at /ws/ and every other request proxied to Gleam
node websocket_relay.js
```

Open `http://localhost:8080`. One port serves slides, remotes and the
WebSocket, so a single tunnel or reverse-proxy rule is enough
(`cloudflared tunnel --url http://localhost:8080`). `./start.sh` does both.

On the screen everyone watches, open the presentation with `?proyector=1`
(the URL in the upload result already has it). That window is the one the
remotes drive; any other window with the same code follows it.

### Tests

```bash
npm test   # simulated projector, stale tabs and phones against the relay
```

## HTML decks (manim-slides)

Any Reveal.js deck can be uploaded as `.html`; cast adds
`<script src="/assets/cast-remote.js" data-cast-code="...">` before `</body>`
and serves it as is. Assets must be inside the file, so for manim-slides use:

```bash
manim-slides convert --one-file MyScene talk.html
```

Fill in the optional cast code on the upload form to keep the same code across
re-uploads. The audience can follow the slides on their phones at `/join`.

## Environment Variables

| Variable | Description | Default |
|----------|-------------|----------|
| `WEBSOCKET_URL` | Where browsers open the relay. Empty means same origin `/ws/` | empty |
| `PUBLIC_URL` | Base URL in QR codes (e.g. `https://cast.example.com`). Empty means taken from the request (`X-Forwarded-*` aware) | empty |
| `SERVER_HOST` | Gleam bind address | `0.0.0.0` |
| `SERVER_PORT` | Gleam port | `6767` |
| `CODES_FILE` | Cast codes survive restarts here | `./data/codes.tsv` |
| `RELAY_PORT` | Relay port (HTTP + WebSocket) | `8080` |
| `GLEAM_URL` | Where the relay proxies HTTP | `http://127.0.0.1:6767` |
| `CAST_STATE_FILE` | Last slide of each room, survives relay restarts | `./relay-state.json` |
| `CAST_SECRET` | Signs control keys (any long random string). Empty means `CAST_SECRET_FILE` | empty |
| `CAST_SECRET_FILE` | Created by the Gleam server on first start (mode 600); the relay reads it | `./data/cast-secret` |
| `LONG_POLL_MS` | How long an HTTP fallback poll waits for news | `25000` |
| `SLIDES_DIR` | Slides output directory | `./slides` |
| `VIEW_DIR` | Presentation HTML directory | `./view` |
| `QR_DIR` | QR code directory | `./qr` |

## How sync works

The relay owns the slide state of each room (cast code):

- **Code vs. control key.** The cast code is public: it is in every audience
  page and on screen, and with it anyone can follow the slides (`/join`).
  Steering needs the control key, `HMAC-SHA256(secret, "cast-control:" + code)`,
  which only appears in the presenter's page (where the upload lands), its
  "Go to Slides" and "Go to Controls" links and its QR. Without the key a
  connection cannot send commands, read the speaker notes or become the
  projector. The projector moves the key from its address bar into the tab's
  session, so it is not shown to the room. Gleam and the relay share the
  secret (`CAST_SECRET` or `data/cast-secret`); with no secret the relay
  refuses all control.

- Exactly one presentation is the **principal**: the newest keyed one opened
  with `?proyector=1`, or else the oldest keyed one. Remote commands go only to
  it and only its state counts. Every other window and every phone mirrors that
  absolute state, so a forgotten tab can no longer drag the room around.
- A principal that reloads (or a new one) resumes the room's slide instead of
  slide 1.
- Commands carry an id; repeats (double taps, resends after a reconnect) are
  dropped, and the phone gets an `ack` saying whether a screen received it.
  Phones show "Projector offline" when nothing is listening.
- Heartbeat every 20 s (WebSocket ping plus `{type:"hb"}`); clients treat 45 s
  of silence as a dead link and reconnect with backoff (1 s up to 10 s).
- Codes are refused unless they match `[A-Za-z0-9_-]{1,32}`. Uploading under
  a code that is already in use needs that code's control key (the `k` form
  field, which "Replace slides" on the presenter page fills in); without it
  the upload is refused. Usernames and file names are reduced to
  `[A-Za-z0-9 ._()-]` before they become paths. Codes created before control
  keys existed have no link carrying their key: upload under a new code.
- **Prediction (low latency):** the principal reports where `next` and `prev`
  would land. When a phone taps, the relay forwards the command to the
  projector and, at the same moment, sends that predicted slide to phones and
  audience screens, so they do not wait for the projector's round trip. The
  projector's real report then confirms it. Going back into a vertical stack
  is not predicted; it just waits for the projector.
- **Teleprompter:** the principal sends an outline (title and
  `<aside class="notes">` of every slide) to the relay, which passes it only to
  remotes, never to audience screens. The server also strips the notes out of
  the deck page unless it is asked for with the key, so the audience cannot
  read them in the page source.
- **HTTP fallback:** when WebSockets are blocked (school or office proxies),
  phones and audience screens switch to long polling after two failed
  attempts. The projector still needs the WebSocket.

```
GET  /relay/room/CODE?since=VERSION&type=controller&k=KEY&ov=OUTLINE_VERSION   long poll
GET  /relay/room/CODE?since=VERSION                     audience long poll (no key)
POST /relay/room/CODE/cmd   body: {"action":"next","id":"...","k":"KEY"}   (text/plain is fine)
GET  /relay/health
```

Phone controls: tap the left third to go back and the rest to go forward, or
swipe. Tap the counter to jump to any slide. The timer starts on the first
command (tap to pause, hold to reset). The page asks the phone to keep its
screen on (Wake Lock; needs https).

Protocol (old clients still work):

```
remote       -> {type:"cmd", action:"next"|"prev"|"goto", indexh?, indexv?, id?}   (needs k)
presentation -> {type:"state", indexh, indexv, indexf?, total, next?, prev?}
presentation -> {type:"outline", slides:[{h, v, title, notes}]}   (principal only)
relay        -> state (predicted?) | outline | {type:"rol", principal, state?} | presence | ack | hb
```

## Directory Structure

```
cast/
├── src/              # Gleam source code
├── public/            # Static assets
│   └── assets/
│       ├── css/      # Stylesheets
│       ├── js/       # JavaScript files
│       ├── fonts/    # Font files
│       └── vendor/   # Third-party libraries
├── slides/           # Generated slide images
├── view/             # Generated presentation HTML
├── qr/               # Generated QR codes
├── websocket_relay.js # WebSocket relay server
├── setup.sh          # Asset setup script
├── flake.nix         # Nix package definition
└── gleam.toml        # Gleam project config
```

## Architecture

### Components

1. **Gleam Server** (`src/cast.gleam`)
   - HTTP server on port 6767
   - Handles file uploads and conversions
   - Serves static files
   - Manages cast codes via OTP actor

2. **Relay** (`websocket_relay.js`)
   - One port (8080): WebSocket at `/ws/`, HTTP proxied to Gleam
   - Keeps each room's state and picks the principal screen (see "How sync works")

3. **Document Processor** (`src/document.gleam`)
   - Converts PDF to PNG using pdftoppm
   - Converts PPTX to PNG using LibreOffice
   - Optimizes PNGs using pngquant
   - Generates presentation HTML with Reveal.js
   - Creates QR codes using qrrs

Presentations: `ws://host:8080/ws/?cast_code={code}&type=presentation[&rol=proyector]`
Controllers: `ws://host:8080/ws/?cast_code={code}&type=controller[&quien=name]`

