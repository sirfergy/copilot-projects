import Foundation
import CopilotProjectsProtocol

enum RemoteWebAssets {
    static let html = #"""
    <!doctype html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
      <meta name="referrer" content="no-referrer">
      <meta name="theme-color" content="#111111">
      <title>Copilot Projects</title>
      <link rel="stylesheet" href="app.css">
      <link rel="manifest" href="manifest.webmanifest">
      <link rel="apple-touch-icon" href="icon-192.png">
    </head>
    <body>
      <header>
        <strong>Copilot Projects</strong>
        <select id="new-session-project" aria-label="New session project" disabled></select>
        <button id="new-session" aria-label="New session" title="New session" disabled>
          New Session
        </button>
        <button id="close-session" aria-label="Close session"
          title="Close session" disabled>
          Close Session
        </button>
        <span id="create-status" class="create-status" role="status" aria-live="polite"
          aria-atomic="true"></span>
        <span id="connection" class="connection connecting" role="status"
          aria-label="Connecting" title="Connecting">
          <span class="connection-dot" aria-hidden="true"></span>
          <span class="visually-hidden">Connecting</span>
        </span>
      </header>
      <main>
        <nav id="sessions"></nav>
        <div id="content" data-mode="conversation">
          <div id="pivot">
            <div id="pivot-tabs" role="tablist" aria-label="Session view">
              <button id="tab-conversation" class="pivot-tab" type="button" role="tab"
                aria-selected="true" aria-controls="transcript-pane"
                data-mode="conversation">Conversation</button>
              <button id="tab-terminal" class="pivot-tab" type="button" role="tab"
                aria-selected="false" aria-controls="terminal-pane"
                data-mode="terminal">Terminal</button>
            </div>
            <button id="notifications" aria-label="Enable web notifications"
              title="Enable web notifications">🔔</button>
          </div>
          <aside id="transcript-pane" role="tabpanel" aria-label="Conversation">
            <div id="transcript-header">
              <strong>Completed turns</strong>
              <span id="prompt-status" role="status" aria-live="polite" aria-atomic="true">
                Select a Copilot session
              </span>
            </div>
            <div id="transcript" aria-live="polite">Select a session</div>
            <div id="user-input" role="group" aria-label="Copilot questions"></div>
            <div id="prompt-queue" role="list" aria-label="Queued messages" hidden></div>
            <form id="prompt-form">
              <textarea id="prompt" rows="3" maxlength="8192" aria-describedby="prompt-warning"
                aria-label="Message Copilot" placeholder="Message Copilot"></textarea>
              <div id="prompt-footer">
                <div id="prompt-warning">Sending clears any unsent desktop draft.</div>
                <button id="model-line" type="button" hidden aria-haspopup="dialog">
                  <span id="model-line-name">Model</span>
                  <span id="model-line-chevron" aria-hidden="true">&#9662;</span>
                </button>
              </div>
              <button id="prompt-submit" disabled>Send message</button>
            </form>
          </aside>
          <section id="terminal-pane" role="tabpanel" aria-label="Terminal">
            <div id="toolbar">
              <button data-key="esc">Esc</button>
              <button data-key="ctrl-c">Ctrl-C</button>
              <button data-key="tab">Tab</button>
              <button data-key="enter" aria-label="Enter" title="Enter">⏎</button>
              <button data-key="up">↑</button>
              <button data-key="down">↓</button>
              <span id="lease">view only</span>
            </div>
            <div id="terminal" role="region" aria-live="off"
              aria-label="Terminal output" tabindex="0">
              <div id="terminal-grid">
                <div id="terminal-lines" class="terminal-lines">Select a session</div>
                <div id="terminal-image-overlay" class="terminal-image-overlay"
                  aria-hidden="true"></div>
              </div>
            </div>
            <div id="terminal-cell-probe" class="terminal-cell-probe"
              aria-hidden="true">MMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMM</div>
            <form id="input-form">
              <input id="input" autocomplete="off" autocapitalize="none" spellcheck="false"
                aria-label="Command input" placeholder="Send a command">
              <button>Send</button>
            </form>
          </section>
        </div>
      </main>
      <div id="image-lightbox" role="dialog" aria-modal="true"
        aria-label="Image viewer" aria-hidden="true">
        <button class="image-lightbox-close" type="button"
          aria-label="Close image viewer">&times;</button>
        <img class="image-lightbox-img" alt="Expanded terminal image" draggable="false">
        <div class="image-lightbox-hint">Scroll or pinch to zoom · drag to pan · Esc to close</div>
      </div>
      <dialog id="model-picker" aria-labelledby="model-picker-title">
        <div id="model-picker-head">
          <button id="model-picker-back" type="button" hidden
            aria-label="Back to model list">&#8249;</button>
          <strong id="model-picker-title">Model</strong>
          <button id="model-picker-close" type="button" aria-label="Close">&times;</button>
        </div>
        <div id="model-picker-body"></div>
        <div id="model-picker-status" role="status" aria-live="polite"></div>
      </dialog>
      <script src="app.js"></script>
    </body>
    </html>
    """#

    static let manifest = #"""
    {
      "id": "/",
      "name": "Copilot Projects",
      "short_name": "Projects",
      "description": "Secure remote control for Copilot Projects sessions",
      "start_url": "/",
      "scope": "/",
      "display": "standalone",
      "background_color": "#111111",
      "theme_color": "#111111",
      "icons": [
        {"src": "/icon-192.png", "sizes": "192x192", "type": "image/png"},
        {"src": "/icon-512.png", "sizes": "512x512", "type": "image/png"}
      ]
    }
    """#

    static let serviceWorker = #"""
    self.addEventListener('install', (event) => {
      event.waitUntil(self.skipWaiting());
    });
    self.addEventListener('activate', (event) => {
      event.waitUntil(self.clients.claim());
    });

    self.addEventListener('push', (event) => {
      let payload;
      try {
        payload = event.data?.json() || {};
      } catch {
        payload = {};
      }
      if (payload.action === 'clear') {
        event.waitUntil((async () => {
          if (!payload.id) return;
          const notifications = await self.registration.getNotifications({
            tag: payload.id
          });
          notifications.forEach((notification) => notification.close());
        })());
        return;
      }
      const sentAt = Date.parse(payload.sentAt || '') || Date.now();
      const sentTime = new Date(sentAt).toLocaleTimeString([], {
        hour: 'numeric',
        minute: '2-digit'
      });
      const body = [payload.body, `Sent at ${sentTime}`]
        .filter(Boolean).join('\n');
      event.waitUntil(self.registration.showNotification(
        payload.title || 'Copilot Projects',
        {
          body: body || `Sent at ${sentTime}`,
          tag: payload.id || undefined,
          timestamp: sentAt,
          icon: '/icon-192.png',
          badge: '/icon-192.png',
          data: {
            id: payload.id || null,
            projectId: payload.projectId || null,
            sessionId: payload.sessionId || null
          }
        }
      ));
    });

    self.addEventListener('notificationclick', (event) => {
      event.notification.close();
      const data = event.notification.data || {};
      const query = new URLSearchParams();
      if (data.projectId) query.set('project', data.projectId);
      if (data.sessionId) query.set('session', data.sessionId);
      const url = new URL(`./?${query.toString()}`, self.registration.scope).href;
      event.waitUntil((async () => {
        if (data.id) {
          await fetch(new URL('\#(NotificationSyncContract.dismissPath)', self.registration.scope), {
            method: 'POST',
            headers: {'Content-Type':'application/json'},
            body: JSON.stringify({id: data.id})
          }).catch(() => {});
        }
        const windows = await clients.matchAll({
          type: 'window',
          includeUncontrolled: true
        });
        if (windows.length) {
          windows[0].postMessage({
            type: 'focus-session',
            projectId: data.projectId,
            sessionId: data.sessionId
          });
          return windows[0].focus();
        }
        return clients.openWindow(url);
      })());
    });

    self.addEventListener('notificationclose', (event) => {
      const id = event.notification.data?.id;
      if (!id) return;
      event.waitUntil(fetch(
        new URL('\#(NotificationSyncContract.dismissPath)', self.registration.scope),
        {
          method: 'POST',
          headers: {'Content-Type':'application/json'},
          body: JSON.stringify({id})
        }
      ).catch(() => {}));
    });
    """#

    static func iconPNG(size: Int) -> Data? {
        let name: String
        switch size {
        case 192: name = "PWAIcon-192"
        case 512: name = "PWAIcon-512"
        default: return nil
        }
        if let url = Bundle.main.url(forResource: name, withExtension: "png"),
           let data = try? Data(contentsOf: url) {
            return data
        }
        let source = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Resources/\(name).png")
        return try? Data(contentsOf: source)
    }

    static let css = #"""
    :root { color-scheme: dark; font-family: -apple-system, BlinkMacSystemFont, sans-serif; }
    * { box-sizing: border-box; }
    html, body { margin: 0; background: #111; color: #eee; overscroll-behavior:none; }
    body { position:fixed; inset:0; width:100%; height: 100vh; height: 100dvh; overflow: hidden;
      display: flex; flex-direction: column; }
    header { flex: 0 0 48px; display:flex; align-items:center; gap:10px;
      padding: 0 14px; border-bottom: 1px solid #333; }
    header strong { margin-right:auto; }
    #new-session-project { min-width:0; width:clamp(96px, 20vw, 160px); max-width:35vw;
      padding:5px 7px; border:1px solid #444; border-radius:6px; background:#1f1f1f;
      color:#eee; text-overflow:ellipsis; }
    #new-session { padding:5px 10px; font-size:12px; border:1px solid #444;
      border-radius:6px; background:#1f6feb; color:#fff; cursor:pointer; }
    #new-session-project:disabled,
    #new-session:disabled { background:#30363d; color:#7d8590; cursor:default; }
    #close-session { padding:5px 10px; font-size:12px; border:1px solid #f8514955;
      border-radius:6px; background:#21262d; color:#f85149; cursor:pointer; }
    #close-session:disabled { background:#30363d; color:#7d8590;
      border-color:#444; cursor:default; }
    .create-status { font-size:11px; color:#8b949e; max-width:220px;
      overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
    .connection { display:inline-flex; align-items:center; justify-content:center;
      width:24px; height:24px; }
    .connection-dot { width:9px; height:9px; border-radius:50%; background:#d29922;
      box-shadow:0 0 0 2px rgba(210,153,34,.18); }
    .connection.connected .connection-dot { background:#3fb950;
      box-shadow:0 0 0 2px rgba(63,185,80,.18); }
    .connection.error .connection-dot, .connection.disconnected .connection-dot {
      background:#f85149; box-shadow:0 0 0 2px rgba(248,81,73,.18); }
    .visually-hidden { position:absolute; width:1px; height:1px; padding:0; margin:-1px;
      overflow:hidden; clip:rect(0,0,0,0); white-space:nowrap; border:0; }
    main { flex:1; min-height:0; display:grid;
      grid-template-columns: minmax(180px, 260px) minmax(0, 1fr); }
    nav { overflow:auto; -webkit-overflow-scrolling:touch; overscroll-behavior:contain;
      border-right:1px solid #333; padding:8px; }
    nav h3 { color:#999; font-size:12px; margin:12px 6px 5px; }
    nav button { display:block; width:100%; text-align:left; margin:2px 0; padding:9px;
      border:0; border-radius:7px; background:transparent; color:#ddd; }
    nav button.active { background:#29334a; }
    nav small { display:block; color:#999; margin-top:3px; }
    #content { min-width:0; min-height:0; display:flex; flex-direction:column; }
    #pivot { flex:0 0 auto; display:flex; align-items:center; gap:8px;
      padding:6px 8px; border-bottom:1px solid #333; }
    #pivot-tabs { display:inline-flex; background:#1b1b1b; border:1px solid #333;
      border-radius:8px; padding:2px; }
    .pivot-tab { background:transparent; border:0; color:#bbb; padding:6px 15px;
      border-radius:6px; font-size:13px; }
    .pivot-tab[aria-selected="true"] { background:#29334a; color:#fff; }
    #pivot #notifications { margin-left:auto; }
    #content > #terminal-pane, #content > #transcript-pane {
      flex:1 1 auto; min-width:0; min-height:0; display:flex; flex-direction:column; }
    #content[data-mode="conversation"] #terminal-pane { display:none; }
    #content[data-mode="terminal"] #transcript-pane { display:none; }
    #toolbar { flex:0 0 auto; display:flex; align-items:center; gap:6px; padding:5px 8px;
      border-bottom:1px solid #333; }
    button { background:#2c2c2c; color:#eee; border:1px solid #444; border-radius:6px;
      padding:7px 10px; }
    #lease { margin-left:auto; color:#999; font-size:12px; }
    #terminal-pane { --terminal-font: 13px/1.25 ui-monospace, SFMono-Regular, Menlo, monospace; }
    #terminal { flex:1; min-height:0; overflow:auto; -webkit-overflow-scrolling:touch;
      overscroll-behavior:contain; margin:0; padding:10px; outline:none;
      font:var(--terminal-font); white-space:pre; touch-action:pan-y; }
    #terminal.terminal-scroll { touch-action:none; }
    #terminal-grid { position:relative; min-width:max-content; }
    .terminal-lines { position:relative; z-index:1; }
    .terminal-line { min-height:1.25em; }
    .terminal-link { color:#58a6ff; text-decoration:underline; text-underline-offset:2px; }
    /* Persistent overlay: reconciled DOM nodes for on-screen terminal images
       are added/moved/removed here without ever replacing `.terminal-lines`,
       so an in-flight image load survives an unrelated text-only re-render.
       `overflow:hidden` clips images to the terminal's own content area. */
    .terminal-image-overlay { position:absolute; inset:0; overflow:hidden; z-index:2;
      pointer-events:none; }
    .terminal-image { position:absolute; top:0; left:0; pointer-events:none;
      object-fit:contain; object-position:top left; }
    /* Hidden fixed-length monospace probe used only to measure the terminal's
       actual cell width (rect.width / probe length) and a line-height
       fallback; `position:fixed` keeps it out of `#terminal`'s own scroll
       area entirely rather than merely invisible inside it. */
    .terminal-cell-probe { position:fixed; left:-9999px; top:-9999px; visibility:hidden;
      white-space:pre; font:var(--terminal-font); pointer-events:none; }
    #notifications.enabled { color:#3fb950; border-color:#238636; }
    #notifications.unsupported, #notifications.denied { opacity:.55; }
    #input-form { flex:0 0 auto; display:flex; gap:8px; padding:8px; border-top:1px solid #333;
      padding-bottom:max(8px, env(safe-area-inset-bottom)); }
    #input { flex:1; min-width:0; background:#222; color:#fff; border:1px solid #555;
      border-radius:7px; padding:10px; font-size:16px; }
    #transcript-pane { background:#161616; }
    #transcript-header { flex:0 0 auto; display:flex; align-items:baseline;
      justify-content:space-between; gap:8px; padding:11px 12px; border-bottom:1px solid #333; }
    #prompt-status { color:#999; font-size:11px; text-align:right; }
    #transcript { flex:1; min-height:0; overflow:auto; -webkit-overflow-scrolling:touch;
      overscroll-behavior:contain; padding:10px; }
    .transcript-empty { color:#888; padding:18px 8px; text-align:center; }
    .show-earlier { justify-self:center; margin:6px auto 10px; padding:6px 14px;
      background:#232323; color:#ddd; border:1px solid #3a3a3a; border-radius:14px;
      font-size:.85rem; cursor:pointer; }
    .show-earlier:hover { background:#2c2c2c; }
    .turn { margin:0 0 12px; padding:10px; border:1px solid #333; border-radius:10px;
      background:#1d1d1d; }
    .turn-header { display:flex; justify-content:space-between; gap:8px;
      color:#999; font-size:11px; margin-bottom:8px; }
    .stopped { color:#d29922; }
    .message { overflow-wrap:anywhere; margin:6px 0; padding:8px; border-radius:7px;
      background:#252525; }
    .message.user { background:#1d3150; }
    .message-label { display:block; color:#999; font-size:10px; font-weight:600;
      margin-bottom:4px; text-transform:uppercase; }
    .markdown { display:grid; gap:8px; min-width:0; }
    .markdown > * { margin:0; }
    .markdown p, .markdown blockquote, .markdown-list-body {
      white-space:pre-wrap; overflow-wrap:anywhere; }
    .markdown h1 { font-size:1.35rem; }
    .markdown h2 { font-size:1.2rem; }
    .markdown h3 { font-size:1.08rem; }
    .markdown h4, .markdown h5, .markdown h6 { font-size:1rem; }
    .markdown h1, .markdown h2, .markdown h3, .markdown h4, .markdown h5,
      .markdown h6 { line-height:1.25; }
    .markdown code { font-family:ui-monospace, SFMono-Regular, Menlo, monospace;
      font-size:.92em; background:rgba(255,255,255,.07); border-radius:4px;
      padding:1px 4px; }
    .markdown pre { max-width:100%; overflow:auto; padding:10px; border-radius:7px;
      background:rgba(255,255,255,.06); }
    .markdown pre code { display:block; min-width:max-content; padding:0;
      background:transparent; white-space:pre; }
    .markdown blockquote { color:#bbb; border-left:3px solid #666; padding-left:9px; }
    .markdown-list { display:grid; gap:4px; }
    .markdown-list-item { display:grid; grid-template-columns:auto minmax(0,1fr); gap:8px;
      padding-left:var(--markdown-indent, 0); }
    .markdown-list-marker { color:#aaa; font-variant-numeric:tabular-nums; }
    .markdown-table-wrap { max-width:100%; overflow:auto; border-radius:7px;
      background:rgba(255,255,255,.04); }
    .markdown table { border-collapse:collapse; min-width:max-content; }
    .markdown th, .markdown td { max-width:280px; padding:7px 9px;
      border:1px solid #444; white-space:pre-wrap; overflow-wrap:anywhere; }
    .markdown th { background:rgba(255,255,255,.05); }
    .tools { color:#aaa; font-size:11px; margin-top:7px; }
    .conversation-images { display:flex; flex-wrap:wrap; gap:8px; margin-top:8px; }
    .conversation-image { margin:0; max-width:100%; }
    .conversation-image-img { display:block; max-width:100%; height:auto;
      max-height:320px; border:1px solid #333; border-radius:8px;
      background:#111; object-fit:contain; cursor:zoom-in; }
    #image-lightbox { position:fixed; inset:0; z-index:1000; display:none;
      align-items:center; justify-content:center; background:rgba(0,0,0,.9);
      touch-action:none; overscroll-behavior:contain; }
    #image-lightbox.open { display:flex; }
    .image-lightbox-img { max-width:100%; max-height:100%; object-fit:contain;
      user-select:none; -webkit-user-drag:none; will-change:transform;
      transform-origin:0 0; cursor:zoom-in; }
    #image-lightbox.zoomed .image-lightbox-img { cursor:grab; }
    #image-lightbox.panning .image-lightbox-img { cursor:grabbing; }
    .image-lightbox-close { position:absolute; top:12px; right:16px; width:40px;
      height:40px; border:none; border-radius:50%; background:rgba(0,0,0,.5);
      color:#fff; font-size:24px; line-height:40px; cursor:pointer; z-index:1; }
    .image-lightbox-close:hover { background:rgba(255,255,255,.18); }
    .image-lightbox-hint { position:absolute; bottom:14px; left:50%;
      transform:translateX(-50%); color:#aaa; font-size:12px; pointer-events:none;
      background:rgba(0,0,0,.4); padding:4px 10px; border-radius:12px; }
    #prompt-queue { flex:0 0 auto; max-height:32%; overflow:auto;
      -webkit-overflow-scrolling:touch; overscroll-behavior:contain;
      display:flex; flex-direction:column; gap:5px; padding:8px 10px 0; }
    .queue-item { display:flex; align-items:flex-start; gap:8px; background:#22262e;
      border:1px solid #333; border-radius:8px; padding:7px 9px; }
    .queue-text { flex:1; min-width:0; white-space:pre-wrap; overflow-wrap:anywhere;
      font-size:13px; color:#ddd; }
    .queue-remove { flex:0 0 auto; background:transparent; border:0; color:#999;
      padding:2px 6px; font-size:12px; line-height:1; }
    .queue-remove:hover { color:#f85149; }
    #prompt-form { flex:0 0 auto; display:grid; gap:7px; padding:10px;
      padding-bottom:max(10px, env(safe-area-inset-bottom)); border-top:1px solid #333; }
    #prompt { width:100%; resize:none; background:#222; color:#fff; border:1px solid #555;
      border-radius:7px; padding:9px; font:16px/1.3 -apple-system, BlinkMacSystemFont, sans-serif; }
    #prompt-warning { color:#999; font-size:10px; }
    #prompt-footer { display:flex; align-items:center; gap:8px; }
    #prompt-footer #prompt-warning { flex:1 1 auto; min-width:0; }
    #model-line { flex:0 0 auto; max-width:55%; display:inline-flex; align-items:center;
      gap:4px; padding:2px 6px; border:0; background:transparent; color:#999;
      font-size:11px; border-radius:6px; cursor:pointer; }
    #model-line[data-interactive="false"] { cursor:default; color:#777; }
    #model-line[data-interactive="false"] #model-line-chevron { display:none; }
    #model-line-name { overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
    #model-line-chevron { font-size:9px; }
    #model-picker { width:min(420px, 92vw); max-height:80vh; padding:0; border:1px solid #333;
      border-radius:12px; background:#1b1b1b; color:#eee; overflow:hidden; }
    #model-picker::backdrop { background:rgba(0,0,0,.6); }
    #model-picker[open] { display:flex; flex-direction:column; }
    #model-picker-head { flex:0 0 auto; display:flex; align-items:center; gap:8px;
      padding:10px 12px; border-bottom:1px solid #333; }
    #model-picker-head strong { flex:1 1 auto; min-width:0; overflow:hidden;
      text-overflow:ellipsis; white-space:nowrap; font-size:14px; }
    #model-picker-head button { padding:2px 9px; font-size:15px; line-height:1.4;
      background:transparent; border:0; color:#bbb; }
    #model-picker-body { flex:1 1 auto; min-height:0; overflow:auto;
      -webkit-overflow-scrolling:touch; overscroll-behavior:contain; padding:10px 12px; }
    #model-picker-status { flex:0 0 auto; padding:0 12px; color:#8b949e; font-size:11px; }
    #model-picker-status:empty { display:none; }
    #model-picker-status.error { color:#f85149; }
    #model-picker-status:not(:empty) { padding:8px 12px; border-top:1px solid #333; }
    .model-group-title { color:#8b949e; font-size:11px; text-transform:uppercase;
      letter-spacing:.04em; margin:12px 2px 5px; }
    .model-group-title:first-child { margin-top:0; }
    .model-row { display:flex; align-items:center; gap:8px; width:100%; margin:2px 0;
      padding:9px 10px; text-align:left; border:0; border-radius:7px;
      background:#222; color:#ddd; font-size:13px; }
    .model-row:disabled { opacity:.45; }
    .model-row-name { flex:1 1 auto; min-width:0; overflow:hidden;
      text-overflow:ellipsis; white-space:nowrap; }
    .model-row-note { color:#8b949e; font-size:11px; }
    .model-row-check { color:#3fb950; }
    .model-current { display:grid; gap:5px; padding:9px 10px; border:1px solid #333;
      border-radius:8px; background:#1f1f1f; }
    .model-current-row { display:flex; align-items:baseline; gap:8px; font-size:12px; }
    .model-current-row dt { flex:0 0 auto; color:#8b949e; margin:0; }
    .model-current-row dd { flex:1 1 auto; min-width:0; margin:0; text-align:right;
      overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
    .model-field { display:grid; gap:5px; margin:12px 0; }
    .model-field label { color:#8b949e; font-size:11px; }
    .model-field select { padding:8px; border:1px solid #444; border-radius:7px;
      background:#222; color:#eee; font-size:14px; }
    .model-toggle { display:flex; align-items:center; gap:8px; font-size:13px; }
    .model-toggle input { width:17px; height:17px; }
    .model-apply { width:100%; margin-top:6px; padding:10px; border:1px solid #1f6feb55;
      border-radius:8px; background:#1f6feb; color:#fff; font-size:14px; }
    .model-apply:disabled { background:#30363d; color:#7d8590; border-color:#444; }
    .model-hint { color:#8b949e; font-size:11px; margin-top:4px; }
    #prompt-submit:disabled { opacity:.5; }
    #prompt-form.hidden { display:none; }
    #user-input { flex:0 0 auto; display:grid; gap:10px; padding:10px;
      border-top:1px solid #333; max-height:55%; overflow:auto;
      -webkit-overflow-scrolling:touch; overscroll-behavior:contain; }
    #user-input:empty { display:none; }
    .user-input-card { display:grid; gap:9px; padding:11px; border:1px solid #3a4a63;
      border-radius:10px; background:#182236; }
    .user-input-head { display:flex; align-items:center; justify-content:space-between;
      gap:8px; color:#9fb4d6; font-size:11px; font-weight:600; text-transform:uppercase; }
    .user-input-agent { color:#c9a227; font-size:10px; font-weight:600;
      text-transform:none; }
    .user-input-question { white-space:pre-wrap; overflow-wrap:anywhere; color:#eee;
      font-size:14px; }
    .user-input-choices { display:grid; gap:7px; }
    .user-input-choice { width:100%; text-align:left; white-space:pre-wrap;
      overflow-wrap:anywhere; padding:9px; border-radius:7px; background:#243350;
      border:1px solid #3a4a63; color:#eaf1ff; }
    .user-input-choice:disabled { opacity:.5; }
    .user-input-freeform { display:grid; gap:7px; }
    .user-input-freeform textarea { width:100%; resize:none; background:#222; color:#fff;
      border:1px solid #555; border-radius:7px; padding:9px;
      font:16px/1.3 -apple-system, BlinkMacSystemFont, sans-serif; }
    .user-input-status { color:#c9a227; font-size:11px; min-height:1em; }
    .elicitation-fields { display:grid; gap:11px; }
    .elicitation-field { display:grid; gap:5px; }
    .elicitation-field-title { color:#9fb4d6; font-size:11px; font-weight:600; }
    .elicitation-field-req { color:#c9a227; }
    .elicitation-field-desc { color:#8fa0bd; font-size:11px; }
    .elicitation-control { width:100%; box-sizing:border-box; background:#222; color:#fff;
      border:1px solid #555; border-radius:7px; padding:9px;
      font:16px/1.3 -apple-system, BlinkMacSystemFont, sans-serif; }
    textarea.elicitation-control { resize:none; }
    .elicitation-hint { color:#8fa0bd; font-size:10px; }
    .elicitation-check { display:flex; align-items:center; gap:8px; color:#eaf1ff;
      font-size:14px; }
    .elicitation-multi { display:grid; gap:6px; }
    .elicitation-multi-option { display:flex; align-items:center; gap:8px; width:100%;
      text-align:left; padding:9px; border-radius:7px; background:#243350;
      border:1px solid #3a4a63; color:#eaf1ff; }
    .elicitation-multi-option[aria-pressed="true"] { border-color:#539bf5; background:#2b3f63; }
    .elicitation-multi-option:disabled { opacity:.5; }
    .elicitation-actions { display:flex; align-items:center; gap:8px; }
    .elicitation-actions .spacer { flex:1 1 auto; }
    .elicitation-decline, .elicitation-submit { padding:9px 12px; border-radius:7px;
      border:1px solid #3a4a63; background:#243350; color:#eaf1ff; }
    .elicitation-submit { background:#238636; border-color:#2ea043; color:#fff; }
    .elicitation-submit:disabled, .elicitation-decline:disabled { opacity:.5; }
    .elicitation-open { display:inline-block; padding:9px 12px; border-radius:7px;
      background:#238636; border:1px solid #2ea043; color:#fff; text-decoration:none;
      width:max-content; }
    .elicitation-url { color:#9fb4d6; font-size:12px; overflow-wrap:anywhere; }
    .elicitation-fallback { color:#9fb4d6; font-size:12px; }
    @media (max-width: 700px) {
      header { flex:0 0 auto; min-height:48px; flex-wrap:wrap; gap:6px; padding:6px 8px; }
      header strong { display:none; }
      #new-session-project { width:min(38vw, 140px); max-width:38vw; }
      .create-status { flex:1 1 100%; max-width:none; }
      .create-status:empty { display:none; }
      main { grid-template-columns: 92px minmax(0, 1fr); }
      nav { padding:4px; }
      nav button { padding:7px 5px; font-size:12px; }
      #terminal, .terminal-cell-probe { font-size:10px; }
      #terminal { padding:6px; }
      #toolbar button { padding:6px 8px; }
      #toolbar { flex-wrap:wrap; height:auto; }
      .pivot-tab { padding:6px 11px; }
    }
    """#

    static let markdownJavascript = #"""
    const MARKDOWN_MAX_LENGTH = 256 * 1024;
    const MARKDOWN_MAX_LINES = 500;
    const MARKDOWN_MAX_PIPES = 1000;
    const MARKDOWN_INLINE_MAX_DEPTH = 12;
    const MARKDOWN_INLINE_MAX_NODES = 5000;
    const MARKDOWN_INLINE_SEARCH_WINDOW = 500;

    function normalizeMarkdownLineEndings(text) {
      return text.replace(/\r\n?/g, '\n');
    }

    function markdownWithinRenderingLimits(text) {
      if (text.length > MARKDOWN_MAX_LENGTH) return false;
      const normalized = normalizeMarkdownLineEndings(text);
      let lines = 1;
      let pipes = 0;
      for (const character of normalized) {
        if (character === '\n') {
          lines += 1;
          if (lines > MARKDOWN_MAX_LINES) return false;
        } else if (character === '|') {
          pipes += 1;
          if (pipes > MARKDOWN_MAX_PIPES) return false;
        }
      }
      return true;
    }

    function markdownFenceLength(line) {
      let ticks = 0;
      while (line[ticks] === '`') ticks += 1;
      return ticks >= 3 ? ticks : 0;
    }

    function markdownIsClosingFence(line, openLength) {
      if (line.length < openLength) return false;
      for (const character of line) {
        if (character !== '`') return false;
      }
      return true;
    }

    function markdownHeading(line) {
      let level = 0;
      while (line[level] === '#') level += 1;
      if (level < 1 || level > 6 || line[level] !== ' ') return null;
      return { level, text: line.slice(level + 1).trim() };
    }

    function markdownListItem(line) {
      let leading = 0;
      let indentation = 0;
      while (line[leading] === ' ' || line[leading] === '\t') {
        indentation += line[leading] === '\t' ? 4 : 1;
        leading += 1;
      }
      const body = line.slice(leading);
      const unordered = body.match(/^([-+*]) +(.*)$/);
      if (unordered) {
        return { marker: '\u2022', text: unordered[2], depth: Math.floor(indentation / 2) };
      }
      const ordered = body.match(/^(\d+\.) +(.*)$/);
      if (ordered) {
        return {
          marker: ordered[1],
          text: ordered[2],
          depth: Math.floor(indentation / 2)
        };
      }
      return null;
    }

    function markdownIsBlockStart(line) {
      return markdownFenceLength(line) > 0
        || markdownHeading(line) !== null
        || line.startsWith('>');
    }

    function markdownRowHasPipe(line) {
      let backslashes = 0;
      for (const character of line) {
        if (character === '|' && backslashes % 2 === 0) return true;
        backslashes = character === '\\' ? backslashes + 1 : 0;
      }
      return false;
    }

    function splitMarkdownTableRow(line) {
      const cells = [];
      let current = '';
      let backslashes = 0;
      for (const character of line) {
        if (character === '|') {
          if (backslashes % 2 === 0) {
            cells.push(current);
            current = '';
          } else {
            current = current.slice(0, -1) + '|';
          }
        } else {
          current += character;
        }
        backslashes = character === '\\' ? backslashes + 1 : 0;
      }
      cells.push(current);
      const trimmed = cells.map((cell) => cell.trim());
      if (trimmed[0] === '') trimmed.shift();
      if (trimmed[trimmed.length - 1] === '') trimmed.pop();
      return trimmed;
    }

    function markdownTableAlignments(line) {
      if (!markdownRowHasPipe(line)) return null;
      const cells = splitMarkdownTableRow(line);
      if (!cells.length) return null;
      const alignments = [];
      for (const cell of cells) {
        const leading = cell.startsWith(':');
        const trailing = cell.endsWith(':');
        const dashes = cell.slice(leading ? 1 : 0, trailing ? -1 : undefined);
        if (dashes.length < 3 || !dashes.split('').every((character) => character === '-')) {
          return null;
        }
        alignments.push(leading && trailing ? 'center' : trailing ? 'right' : 'left');
      }
      return alignments;
    }

    function parseMarkdownBlocks(value) {
      const text = normalizeMarkdownLineEndings(String(value ?? ''));
      const lines = text.split('\n');
      const blocks = [];
      let paragraph = [];
      let index = 0;

      const flushParagraph = () => {
        if (!paragraph.length) return;
        blocks.push({ type: 'paragraph', text: paragraph.join('\n') });
        paragraph = [];
      };

      while (index < lines.length) {
        const line = lines[index];
        const trimmed = line.trim();
        const fenceLength = markdownFenceLength(trimmed);
        if (fenceLength) {
          flushParagraph();
          const code = [];
          index += 1;
          while (index < lines.length
              && !markdownIsClosingFence(lines[index].trim(), fenceLength)) {
            code.push(lines[index]);
            index += 1;
          }
          if (index < lines.length) index += 1;
          blocks.push({ type: 'code', text: code.join('\n') });
          continue;
        }

        if (!trimmed) {
          flushParagraph();
          index += 1;
          continue;
        }

        const heading = markdownHeading(trimmed);
        if (heading) {
          flushParagraph();
          blocks.push({ type: 'heading', level: heading.level, text: heading.text });
          index += 1;
          continue;
        }

        if (trimmed.startsWith('>')) {
          flushParagraph();
          const quote = [];
          while (index < lines.length) {
            const candidate = lines[index].trim();
            if (!candidate.startsWith('>')) break;
            quote.push(candidate.slice(1).trim());
            index += 1;
          }
          blocks.push({ type: 'quote', text: quote.join('\n') });
          continue;
        }

        if (markdownListItem(line)) {
          flushParagraph();
          const items = [];
          while (index < lines.length) {
            const item = markdownListItem(lines[index]);
            if (item) {
              items.push(item);
              index += 1;
              continue;
            }
            const continuation = lines[index].trim();
            if (items.length && continuation && !markdownIsBlockStart(continuation)) {
              items[items.length - 1].text += ` ${continuation}`;
              index += 1;
              continue;
            }
            break;
          }
          blocks.push({ type: 'list', items });
          continue;
        }

        if (index + 1 < lines.length && markdownRowHasPipe(trimmed)) {
          const alignments = markdownTableAlignments(lines[index + 1].trim());
          const header = splitMarkdownTableRow(trimmed);
          if (alignments && header.length === alignments.length) {
            flushParagraph();
            index += 2;
            const rows = [];
            while (index < lines.length) {
              const row = lines[index].trim();
              if (!row || !markdownRowHasPipe(row)) break;
              if (!row.startsWith('|')) {
                if (markdownIsBlockStart(row)) break;
                const item = markdownListItem(lines[index]);
                if (item && !item.text.startsWith('|')) break;
              }
              rows.push(splitMarkdownTableRow(row));
              index += 1;
            }
            blocks.push({ type: 'table', header, alignments, rows });
            continue;
          }
        }

        paragraph.push(line);
        index += 1;
      }

      flushParagraph();
      return blocks;
    }

    function markdownAnchor(href, label) {
      let url = null;
      try { url = new URL(href); } catch (_) {}
      if (!url || (url.protocol !== 'https:' && url.protocol !== 'http:')) return null;
      const anchor = document.createElement('a');
      anchor.className = 'terminal-link';
      anchor.href = url.href;
      anchor.target = '_blank';
      anchor.rel = 'noopener noreferrer';
      anchor.textContent = label;
      anchor.onclick = (event) => event.stopPropagation();
      return anchor;
    }

    // Finds `needle` within a bounded window starting at `start` so a single
    // delimiter search never scans more than MARKDOWN_INLINE_SEARCH_WINDOW
    // characters. Without this, adversarial input (e.g. a long run of `[`
    // with no closing `](`) makes every cursor position rescan the rest of
    // the string, which is quadratic in the input length.
    function boundedIndexOf(text, needle, start) {
      if (start >= text.length) return -1;
      const end = Math.min(text.length, start + MARKDOWN_INLINE_SEARCH_WINDOW);
      const found = text.slice(start, end).indexOf(needle);
      return found === -1 ? -1 : start + found;
    }

    function appendMarkdownInline(parent, value, depth = 0, budget = { remaining: MARKDOWN_INLINE_MAX_NODES }) {
      const text = String(value ?? '');
      if (depth >= MARKDOWN_INLINE_MAX_DEPTH || budget.remaining <= 0) {
        parent.append(document.createTextNode(text));
        return;
      }

      let cursor = 0;
      let plainStart = 0;
      const appendNode = (node) => {
        parent.append(node);
        budget.remaining -= 1;
      };
      const flushPlain = (end) => {
        if (end > plainStart) {
          appendNode(document.createTextNode(text.slice(plainStart, end)));
        }
      };
      // CommonMark only treats a lone "_" as emphasis when it isn't nestled
      // between two word characters, so identifiers like "snake_case_id"
      // stay literal while " _italic_ " still renders as emphasis.
      const isWordCharacter = (char) => char !== undefined && /[A-Za-z0-9]/.test(char);
      const isIntrawordUnderscore = (openStart, closeStart, markerLength) =>
        isWordCharacter(text[openStart - 1]) && isWordCharacter(text[closeStart + markerLength]);

      while (cursor < text.length) {
        if (budget.remaining <= 0) break;

        if (text[cursor] === '\\' && cursor + 1 < text.length
            && '\\`*[]()_~'.includes(text[cursor + 1])) {
          flushPlain(cursor);
          appendNode(document.createTextNode(text[cursor + 1]));
          cursor += 2;
          plainStart = cursor;
          continue;
        }

        if (text[cursor] === '`') {
          let ticks = 1;
          while (text[cursor + ticks] === '`') ticks += 1;
          const marker = '`'.repeat(ticks);
          const close = boundedIndexOf(text, marker, cursor + ticks);
          if (close >= 0) {
            flushPlain(cursor);
            const code = document.createElement('code');
            code.textContent = text.slice(cursor + ticks, close);
            appendNode(code);
            cursor = close + ticks;
            plainStart = cursor;
            continue;
          }
        }

        if (text.startsWith('![', cursor)) {
          const labelEnd = boundedIndexOf(text, '](', cursor + 2);
          const urlEnd = labelEnd >= 0 ? boundedIndexOf(text, ')', labelEnd + 2) : -1;
          if (labelEnd >= 0 && urlEnd >= 0) {
            flushPlain(cursor);
            appendNode(document.createTextNode(
              `[Image: ${text.slice(cursor + 2, labelEnd)}]`
            ));
            cursor = urlEnd + 1;
            plainStart = cursor;
            continue;
          }
        }

        if (text[cursor] === '[') {
          const labelEnd = boundedIndexOf(text, '](', cursor + 1);
          const urlEnd = labelEnd >= 0 ? boundedIndexOf(text, ')', labelEnd + 2) : -1;
          if (labelEnd >= 0 && urlEnd >= 0) {
            const label = text.slice(cursor + 1, labelEnd);
            const anchor = markdownAnchor(text.slice(labelEnd + 2, urlEnd), label);
            if (anchor) {
              flushPlain(cursor);
              appendNode(anchor);
              cursor = urlEnd + 1;
              plainStart = cursor;
              continue;
            }
          }
        }

        if (text.startsWith('http://', cursor) || text.startsWith('https://', cursor)) {
          let end = cursor;
          while (end < text.length && !/[\s<>()\[\]]/.test(text[end])) end += 1;
          while (end > cursor && '.,;:!?'.includes(text[end - 1])) end -= 1;
          const href = text.slice(cursor, end);
          const anchor = markdownAnchor(href, href);
          if (anchor) {
            flushPlain(cursor);
            appendNode(anchor);
            cursor = end;
            plainStart = cursor;
            continue;
          }
        }

        const pairedMarkers = [
          ['**', 'strong'],
          ['__', 'strong'],
          ['~~', 'del'],
          ['*', 'em'],
          ['_', 'em']
        ];
        let matched = false;
        for (const [marker, tag] of pairedMarkers) {
          if (!text.startsWith(marker, cursor)) continue;
          const close = boundedIndexOf(text, marker, cursor + marker.length);
          if (close <= cursor + marker.length) continue;
          if (marker === '_' && isIntrawordUnderscore(cursor, close, marker.length)) continue;
          flushPlain(cursor);
          const element = document.createElement(tag);
          appendMarkdownInline(
            element,
            text.slice(cursor + marker.length, close),
            depth + 1,
            budget
          );
          appendNode(element);
          cursor = close + marker.length;
          plainStart = cursor;
          matched = true;
          break;
        }
        if (matched) continue;

        cursor += 1;
      }

      flushPlain(text.length);
    }

    function appendMarkdown(parent, value) {
      const text = String(value ?? '');
      const body = document.createElement('div');
      body.className = 'markdown';
      if (!markdownWithinRenderingLimits(text)) {
        const paragraph = document.createElement('p');
        appendLinkedText(paragraph, text);
        body.append(paragraph);
        parent.append(body);
        return;
      }

      // Shared across every inline call for this document render so a
      // pathological input (e.g. thousands of tiny bold spans) can't
      // amplify into an unbounded number of DOM nodes.
      const inlineBudget = { remaining: MARKDOWN_INLINE_MAX_NODES };

      parseMarkdownBlocks(text).forEach((block) => {
        if (block.type === 'heading') {
          const heading = document.createElement(`h${block.level}`);
          appendMarkdownInline(heading, block.text, 0, inlineBudget);
          body.append(heading);
        } else if (block.type === 'paragraph') {
          const paragraph = document.createElement('p');
          appendMarkdownInline(paragraph, block.text, 0, inlineBudget);
          body.append(paragraph);
        } else if (block.type === 'code') {
          const pre = document.createElement('pre');
          const code = document.createElement('code');
          code.textContent = block.text;
          pre.append(code);
          body.append(pre);
        } else if (block.type === 'quote') {
          const quote = document.createElement('blockquote');
          appendMarkdownInline(quote, block.text, 0, inlineBudget);
          body.append(quote);
        } else if (block.type === 'list') {
          const list = document.createElement('div');
          list.className = 'markdown-list';
          list.setAttribute('role', 'list');
          block.items.forEach((item) => {
            const row = document.createElement('div');
            row.className = 'markdown-list-item';
            row.setAttribute('role', 'listitem');
            row.style.setProperty(
              '--markdown-indent',
              `${Math.min(item.depth, 6) * 14}px`
            );
            const marker = document.createElement('span');
            marker.className = 'markdown-list-marker';
            marker.textContent = item.marker;
            const itemBody = document.createElement('span');
            itemBody.className = 'markdown-list-body';
            appendMarkdownInline(itemBody, item.text, 0, inlineBudget);
            row.append(marker, itemBody);
            list.append(row);
          });
          body.append(list);
        } else if (block.type === 'table') {
          const wrapper = document.createElement('div');
          wrapper.className = 'markdown-table-wrap';
          const table = document.createElement('table');
          const head = document.createElement('thead');
          const headerRow = document.createElement('tr');
          block.header.forEach((value, column) => {
            const cell = document.createElement('th');
            cell.style.textAlign = block.alignments[column] || 'left';
            appendMarkdownInline(cell, value, 0, inlineBudget);
            headerRow.append(cell);
          });
          head.append(headerRow);
          table.append(head);
          const bodyRows = document.createElement('tbody');
          block.rows.forEach((values) => {
            const row = document.createElement('tr');
            block.header.forEach((_, column) => {
              const cell = document.createElement('td');
              cell.style.textAlign = block.alignments[column] || 'left';
              appendMarkdownInline(cell, values[column] || '', 0, inlineBudget);
              row.append(cell);
            });
            bodyRows.append(row);
          });
          table.append(bodyRows);
          wrapper.append(table);
          body.append(wrapper);
        }
      });
      parent.append(body);
    }
    """#

    static let draftJavascript = #"""
    const PROMPT_DRAFT_STORAGE_PREFIX = 'copilot-projects-prompt-draft-v2:';
    const PROMPT_DRAFT_MAX_LENGTH = 8192;
    const PROMPT_DRAFT_MAX_SESSIONS = 100;
    const PROMPT_DRAFT_SAVE_DELAY = 200;
    const promptDrafts = new Map();

    function truncatePromptDraft(value) {
      // String.slice() counts UTF-16 code units, so cutting at exactly
      // PROMPT_DRAFT_MAX_LENGTH can land between the two halves of a
      // surrogate pair (e.g. many emoji), leaving an unpaired high
      // surrogate that renders as a replacement character on the next
      // read. Drop a trailing unpaired high surrogate so truncation
      // always lands on a code-point boundary.
      let sliced = value.slice(0, PROMPT_DRAFT_MAX_LENGTH);
      const lastCode = sliced.charCodeAt(sliced.length - 1);
      if (lastCode >= 0xd800 && lastCode <= 0xdbff) {
        sliced = sliced.slice(0, -1);
      }
      return sliced;
    }
    // Session ids this tab changed since their last successful per-key write.
    const promptDraftDirtySessions = new Set();
    // For sessions marked dirty by capacity eviction (not an intentional
    // prune/clear), the candidate's live updatedAt observed at the moment
    // eviction was decided. The debounced flush can land up to
    // PROMPT_DRAFT_SAVE_DELAY later, which is enough time for another tab to
    // refresh the same candidate; persistPromptDrafts() re-checks this
    // baseline immediately before deleting so that later refresh wins
    // instead of being silently destroyed.
    const promptDraftEvictionBaseline = new Map();
    let promptDraftSaveTimer = null;
    let promptDraftStorageWarningShown = false;

    function promptDraftStorageKey(sessionId) {
      return `${PROMPT_DRAFT_STORAGE_PREFIX}${encodeURIComponent(sessionId)}`;
    }

    function sessionIdForPromptDraftStorageKey(key) {
      if (typeof key !== 'string' || !key.startsWith(PROMPT_DRAFT_STORAGE_PREFIX)) {
        return null;
      }
      try {
        const sessionId = decodeURIComponent(key.slice(PROMPT_DRAFT_STORAGE_PREFIX.length));
        return sessionId && promptDraftStorageKey(sessionId) === key ? sessionId : null;
      } catch (_) {
        return null;
      }
    }

    function warnPromptDraftStorage(error) {
      if (promptDraftStorageWarningShown) return;
      promptDraftStorageWarningShown = true;
      console.warn('Copilot Projects could not persist message drafts.', error);
    }

    function parseStoredPromptDraft(raw) {
      let decoded = null;
      try {
        decoded = JSON.parse(raw);
      } catch (error) {
        warnPromptDraftStorage(error);
        return null;
      }
      if (!decoded || typeof decoded !== 'object' || Array.isArray(decoded)
          || typeof decoded.value !== 'string' || !decoded.value) {
        warnPromptDraftStorage(new Error('Stored message drafts are invalid.'));
        return null;
      }
      const value = truncatePromptDraft(decoded.value);
      const updatedAt = Number.isFinite(decoded.updatedAt) ? decoded.updatedAt : 0;
      return {
        draft: { value, updatedAt },
        corrected: value !== decoded.value || updatedAt !== decoded.updatedAt
      };
    }

    function loadPromptDrafts() {
      const storageKeys = [];
      try {
        for (let index = 0; index < localStorage.length; index += 1) {
          const key = localStorage.key(index);
          if (typeof key === 'string' && key.startsWith(PROMPT_DRAFT_STORAGE_PREFIX)) {
            storageKeys.push(key);
          }
        }
      } catch (error) {
        warnPromptDraftStorage(error);
        return;
      }

      const loaded = [];
      const invalidKeys = [];
      for (const key of storageKeys) {
        const sessionId = sessionIdForPromptDraftStorageKey(key);
        if (!sessionId) {
          invalidKeys.push(key);
          continue;
        }
        let raw = null;
        try {
          raw = localStorage.getItem(key);
        } catch (error) {
          promptDrafts.clear();
          warnPromptDraftStorage(error);
          return;
        }
        const parsed = raw ? parseStoredPromptDraft(raw) : null;
        if (!parsed) {
          invalidKeys.push(key);
          continue;
        }
        loaded.push({ sessionId, key, ...parsed });
      }

      loaded.sort((left, right) => left.draft.updatedAt - right.draft.updatedAt);
      const retained = loaded.slice(-PROMPT_DRAFT_MAX_SESSIONS);
      const excess = loaded.slice(0, -PROMPT_DRAFT_MAX_SESSIONS);
      for (const entry of retained) {
        promptDrafts.set(entry.sessionId, entry.draft);
        if (entry.corrected) promptDraftDirtySessions.add(entry.sessionId);
      }
      for (const entry of excess) {
        promptDraftDirtySessions.add(entry.sessionId);
        promptDraftEvictionBaseline.set(entry.sessionId, {
          value: entry.draft.value,
          updatedAt: entry.draft.updatedAt,
        });
      }

      for (const key of invalidKeys) {
        try {
          localStorage.removeItem(key);
        } catch (error) {
          warnPromptDraftStorage(error);
        }
      }
      if (promptDraftDirtySessions.size) schedulePromptDraftPersistence();
    }

    function persistPromptDrafts() {
      if (promptDraftSaveTimer !== null) {
        clearTimeout(promptDraftSaveTimer);
        promptDraftSaveTimer = null;
      }
      if (!promptDraftDirtySessions.size) return;

      const dirtySessions = Array.from(promptDraftDirtySessions);
      const deletions = dirtySessions.filter((sessionId) => !promptDrafts.has(sessionId));
      const writes = dirtySessions.filter((sessionId) => promptDrafts.has(sessionId));
      for (const sessionId of [...deletions, ...writes]) {
        const isWrite = promptDrafts.has(sessionId);
        if (!isWrite && promptDraftEvictionBaseline.has(sessionId)) {
          // This deletion came from capacity-based eviction. Re-check the
          // live value right before deleting - the debounce window since
          // the eviction decision is enough time for another tab to have
          // refreshed this same candidate, and that refresh must win.
          const baseline = promptDraftEvictionBaseline.get(sessionId);
          let raw = null;
          let readFailed = false;
          try {
            raw = localStorage.getItem(promptDraftStorageKey(sessionId));
          } catch (error) {
            warnPromptDraftStorage(error);
            readFailed = true;
          }
          if (readFailed) {
            // Could not verify whether another tab touched this candidate
            // since the eviction decision was made - proceeding to delete
            // anyway would bypass the freshness guard entirely on exactly
            // the failure it exists to protect against. Leave it dirty and
            // retry the recheck on the next flush instead.
            continue;
          }
          const stored = raw ? parseStoredPromptDraft(raw) : null;
          // Compare the exact stored record against the exact baseline
          // snapshot rather than only `updatedAt > baseline`: Date.now()
          // is millisecond-resolution, so another tab can write a
          // different value within the same millisecond the baseline was
          // captured in, and a timestamp-only comparison would treat that
          // as unchanged. An exact mismatch on either field means some
          // write happened since the decision, regardless of ordering.
          if (
            stored &&
            (stored.draft.value !== baseline.value ||
              stored.draft.updatedAt !== baseline.updatedAt)
          ) {
            // Changed elsewhere since the eviction decision - decline this
            // deletion and leave storage untouched.
            promptDraftDirtySessions.delete(sessionId);
            promptDraftEvictionBaseline.delete(sessionId);
            continue;
          }
        }
        try {
          if (isWrite) {
            localStorage.setItem(
              promptDraftStorageKey(sessionId),
              JSON.stringify(promptDrafts.get(sessionId))
            );
          } else {
            localStorage.removeItem(promptDraftStorageKey(sessionId));
          }
          promptDraftDirtySessions.delete(sessionId);
          promptDraftEvictionBaseline.delete(sessionId);
        } catch (error) {
          warnPromptDraftStorage(error);
        }
      }
    }

    function schedulePromptDraftPersistence() {
      if (promptDraftSaveTimer !== null) clearTimeout(promptDraftSaveTimer);
      promptDraftSaveTimer = setTimeout(
        persistPromptDrafts,
        PROMPT_DRAFT_SAVE_DELAY
      );
    }

    function draftForSession(sessionId) {
      return sessionId ? (promptDrafts.get(sessionId)?.value || '') : '';
    }

    function selectPromptDraftEvictionCandidate() {
      // promptDrafts already reflects everything this tab knows about,
      // including edits it made but hasn't flushed to storage yet - a
      // live-storage-only scan would miss those pending sessions and
      // wrongly conclude there's room to spare. But promptDrafts alone
      // would miss sessions another tab created that this tab never
      // loaded, which is the actual gap: two tabs that each start from an
      // empty store and only ever create their own disjoint sessions would
      // both judge the cap against their own map alone and never notice
      // storage growing well past it. Combine both views - this tab's own
      // record takes precedence for anything it knows, and live storage
      // fills in only the sessions it doesn't - so the cap is judged
      // against every session that exists anywhere, not just the ones a
      // single tab happens to have loaded or created.
      const candidates = [];
      const known = new Set();
      for (const [sessionId, draft] of promptDrafts.entries()) {
        candidates.push({ sessionId, draft });
        known.add(sessionId);
      }

      const storageKeys = [];
      try {
        for (let index = 0; index < localStorage.length; index += 1) {
          const key = localStorage.key(index);
          if (typeof key === 'string' && key.startsWith(PROMPT_DRAFT_STORAGE_PREFIX)) {
            storageKeys.push(key);
          }
        }
      } catch (error) {
        warnPromptDraftStorage(error);
        // Fall back to this tab's own view alone rather than skipping
        // eviction entirely - it still enforces the cap against what this
        // tab actually knows.
        if (candidates.length < PROMPT_DRAFT_MAX_SESSIONS) return null;
        candidates.sort((left, right) => left.draft.updatedAt - right.draft.updatedAt);
        return candidates[0];
      }

      for (const key of storageKeys) {
        const sessionId = sessionIdForPromptDraftStorageKey(key);
        // A session already staged for eviction (promptDraftEvictionBaseline)
        // is still physically present in storage until this tab's next
        // flush actually deletes it, so a naive re-scan would keep finding
        // and re-picking that same not-yet-removed entry on every
        // subsequent call instead of progressing to the next-oldest
        // candidate - one net-new session added would never make more than
        // one eviction happen no matter how many more were added after it.
        // Treat anything already staged as already gone for this decision.
        if (!sessionId || known.has(sessionId) || promptDraftEvictionBaseline.has(sessionId)) {
          continue;
        }
        let raw = null;
        try {
          raw = localStorage.getItem(key);
        } catch (error) {
          warnPromptDraftStorage(error);
          continue;
        }
        const parsed = raw ? parseStoredPromptDraft(raw) : null;
        if (!parsed) continue;
        candidates.push({ sessionId, draft: parsed.draft });
      }

      if (candidates.length < PROMPT_DRAFT_MAX_SESSIONS) {
        // Storage isn't actually at cap once every tab's sessions are
        // counted; nothing needs to be evicted to make room for a new one.
        return null;
      }

      candidates.sort((left, right) => left.draft.updatedAt - right.draft.updatedAt);
      return candidates[0];
    }

    function setPromptDraft(sessionId, value) {
      if (!sessionId) return;
      const normalized = truncatePromptDraft(String(value ?? ''));
      if (!normalized) {
        if (!promptDrafts.delete(sessionId)) return;
        promptDraftDirtySessions.add(sessionId);
        schedulePromptDraftPersistence();
        return;
      }
      if (promptDrafts.get(sessionId)?.value === normalized) return;
      if (promptDrafts.has(sessionId)) {
        promptDrafts.delete(sessionId);
      } else {
        const evicted = selectPromptDraftEvictionCandidate();
        if (evicted) {
          promptDraftEvictionBaseline.set(evicted.sessionId, {
            value: evicted.draft.value,
            updatedAt: evicted.draft.updatedAt,
          });
          promptDrafts.delete(evicted.sessionId);
          promptDraftDirtySessions.add(evicted.sessionId);
        }
      }
      promptDrafts.set(sessionId, { value: normalized, updatedAt: Date.now() });
      promptDraftDirtySessions.add(sessionId);
      schedulePromptDraftPersistence();
    }

    function prunePromptDrafts(activeSessionIds) {
      let changed = false;
      for (const sessionId of promptDrafts.keys()) {
        if (activeSessionIds.has(sessionId)) continue;
        promptDrafts.delete(sessionId);
        promptDraftDirtySessions.add(sessionId);
        changed = true;
      }
      if (changed) schedulePromptDraftPersistence();
    }

    loadPromptDrafts();
    """#

    static let sessionCreationJavascript = #"""
    function chooseCreateProjectId(projects, currentProjectId, hostSelectedProjectId) {
      const projectIds = new Set(projects.map((project) => project.id));
      if (currentProjectId && projectIds.has(currentProjectId)) {
        return currentProjectId;
      }
      if (hostSelectedProjectId && projectIds.has(hostSelectedProjectId)) {
        return hostSelectedProjectId;
      }
      return projects[0]?.id || null;
    }

    function createProjectSignature(projects) {
      return JSON.stringify(projects.map((project) => [project.id, project.name]));
    }
    """#

    // Terminal image rendering (Kitty inline image placements advertised via
    // `RemoteTerminalScreen.images`). Kept isolated from DOM-touching code
    // below so the validation/dedup/PNG/byte-cap logic can be exercised
    // directly under Node without a DOM, mirroring `markdownJavascript`.
    static let terminalImageJavascript = #"""
    // A wire placement's `line`/`column` are relative to the emitted screen
    // (see RemoteTerminalImagePlacement's doc comment); the host's full
    // retained-history scan can report a placement above or below the
    // emitted `lines` window, bounded by this same slack the host itself
    // tolerates, so a client must accept (not reject) that bounded range
    // rather than only ever trusting in-window placements.
    const TERMINAL_IMAGE_RETAINED_LINE_SLACK = 1024;
    // Mirrors the host's own `remoteKittyMaxEmittedPlacements` cap
    // (RemoteKittyGraphics.swift) as defense-in-depth against a malformed or
    // hostile payload, never relying solely on the host to have enforced it.
    const TERMINAL_IMAGE_MAX_PLACEMENTS = 64;
    const TERMINAL_IMAGE_MAX_RENDERED_NODES = 8;
    const TERMINAL_IMAGE_FETCH_TIMEOUT_MS = 15_000;
    const TERMINAL_IMAGE_MAX_IN_FLIGHT = 16;
    const TERMINAL_IMAGE_MAX_RESPONSE_BYTES = 5 * 1024 * 1024;
    const TERMINAL_IMAGE_MAX_POSITIVE_CACHE_ENTRIES = 16;
    const TERMINAL_IMAGE_MAX_POSITIVE_CACHE_BYTES = 24 * 1024 * 1024;
    const TERMINAL_IMAGE_MAX_NEGATIVE_CACHE_ENTRIES = 128;
    const TERMINAL_IMAGE_MAX_BACKOFF_ENTRIES = 128;
    const TERMINAL_IMAGE_MAX_DECODED_PIXELS = 16_000_000;
    const TERMINAL_IMAGE_MAX_DIMENSION = 4096;
    const TERMINAL_IMAGE_MAX_PIXELS = 16_000_000;
    // Conversation inline-image transient-failure retry (capacity/backoff).
    const CONVERSATION_IMAGE_RETRY_MS = 1_500;
    const CONVERSATION_IMAGE_MAX_RETRIES = 3;
    const TERMINAL_IMAGE_BACKOFF_BASE_MS = 1000;
    const TERMINAL_IMAGE_BACKOFF_MAX_MS = 30_000;

    function terminalImageCacheKey(sessionId, imageId, version) {
      return `${sessionId}:${imageId}:${version}`;
    }

    function terminalImageBackoffDelayMs(failureCount) {
      const exponent = Math.max(0, failureCount - 1);
      return Math.min(
        TERMINAL_IMAGE_BACKOFF_BASE_MS * (2 ** exponent),
        TERMINAL_IMAGE_BACKOFF_MAX_MS
      );
    }

    // Validates one wire placement against the *emitted* screen it arrived
    // with (never a cached/prior screen), converting its screen-relative
    // `line` to an absolute, scroll-invariant line number. Returns `null` for
    // anything unsafe rather than throwing, so one bad entry can't break the
    // rest of an otherwise-valid authoritative array.
    function validateTerminalImagePlacement(raw, screen) {
      if (!raw || typeof raw !== 'object') return null;
      const { imageId, contentVersion, contentVersionText, line, column, rows, columns } = raw;
      if (!Number.isSafeInteger(imageId) || imageId < 1 || imageId > 0xFFFFFF) return null;
      const exactVersion = typeof contentVersionText === 'string'
        && /^[1-9][0-9]{0,19}$/.test(contentVersionText)
        ? contentVersionText
        : (Number.isSafeInteger(contentVersion) && contentVersion > 0
          ? String(contentVersion) : null);
      if (!exactVersion) return null;
      if (!Number.isSafeInteger(rows) || rows <= 0 || rows > 1024) return null;
      if (!Number.isSafeInteger(columns) || columns <= 0) return null;
      if (!Number.isSafeInteger(column) || column < 0) return null;
      if (!Number.isSafeInteger(line)) return null;
      const linesLength = Array.isArray(screen?.lines) ? screen.lines.length : 0;
      const lowerBound = -TERMINAL_IMAGE_RETAINED_LINE_SLACK;
      const upperBound = linesLength + TERMINAL_IMAGE_RETAINED_LINE_SLACK;
      if (line < lowerBound || line >= upperBound) return null;
      const rightEdge = column + columns;
      if (!Number.isSafeInteger(rightEdge) || rightEdge > screen.cols) return null;
      if (!Number.isSafeInteger(screen?.firstLine)) return null;
      const absoluteLine = screen.firstLine + line;
      if (!Number.isSafeInteger(absoluteLine)) return null;
      const bottomEdge = absoluteLine + rows;
      if (!Number.isSafeInteger(bottomEdge)) return null;
      return {
        imageId,
        contentVersion: exactVersion,
        absoluteLine,
        column,
        rows,
        columns,
        key: `${imageId}:${exactVersion}:${absoluteLine}:${column}:${rows}:${columns}`
      };
    }

    // Deterministic validate + dedupe + cap: processes the wire array in
    // order, keeps the first occurrence of each distinct placement, and stops
    // once the cap is reached — so the same input always yields the same
    // output regardless of platform/engine.
    function buildTerminalImagePlacements(screen) {
      const raw = Array.isArray(screen?.images) ? screen.images : [];
      const seen = new Set();
      const result = [];
      for (const item of raw) {
        if (result.length >= TERMINAL_IMAGE_MAX_PLACEMENTS) break;
        const placement = validateTerminalImagePlacement(item, screen);
        if (!placement || seen.has(placement.key)) continue;
        seen.add(placement.key);
        result.push(placement);
      }
      return result;
    }

    // Structural PNG validation performed on the raw bytes *before* they're
    // ever wrapped in a Blob/object URL or handed to the browser's own image
    // decoder: signature, a well-formed IHDR immediately following it, and
    // sane/bounded dimensions. Returns `{width, height}` or `null`.
    function validateTerminalImagePngBytes(bytes) {
      if (!bytes || typeof bytes.length !== 'number' || bytes.length < 8 + 8 + 13) return null;
      const signature = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
      for (let index = 0; index < 8; index += 1) {
        if (bytes[index] !== signature[index]) return null;
      }
      const readUInt32BE = (offset) => (
        (bytes[offset] * 0x1000000)
        + (bytes[offset + 1] << 16)
        + (bytes[offset + 2] << 8)
        + bytes[offset + 3]
      );
      const chunkLength = readUInt32BE(8);
      const chunkType = String.fromCharCode(bytes[12], bytes[13], bytes[14], bytes[15]);
      if (chunkType !== 'IHDR' || chunkLength !== 13) return null;
      const width = readUInt32BE(16);
      const height = readUInt32BE(20);
      if (!(width > 0) || !(height > 0)) return null;
      if (width > TERMINAL_IMAGE_MAX_DIMENSION || height > TERMINAL_IMAGE_MAX_DIMENSION) return null;
      const pixels = width * height;
      if (!Number.isSafeInteger(pixels) || pixels > TERMINAL_IMAGE_MAX_PIXELS) return null;
      return { width, height };
    }

    // Streams a fetch `Response` body into a single `Uint8Array`, rejecting
    // as soon as either a declared `Content-Length` or the actual streamed
    // total exceeds `maxBytes` — a chunked/unknown-length response can't
    // bypass the cap simply by omitting the header.
    async function readBoundedTerminalImageBody(response, maxBytes) {
      const declaredLength = Number(response.headers?.get?.('content-length'));
      if (Number.isFinite(declaredLength) && declaredLength > maxBytes) {
        throw new Error('terminal-image-too-large');
      }
      const reader = response.body?.getReader ? response.body.getReader() : null;
      if (!reader) {
        const buffer = await response.arrayBuffer();
        if (buffer.byteLength > maxBytes) throw new Error('terminal-image-too-large');
        return new Uint8Array(buffer);
      }
      const chunks = [];
      let total = 0;
      for (;;) {
        const { done, value } = await reader.read();
        if (done) break;
        total += value.byteLength;
        if (total > maxBytes) {
          await reader.cancel().catch(() => {});
          throw new Error('terminal-image-too-large');
        }
        chunks.push(value);
      }
      const combined = new Uint8Array(total);
      let offset = 0;
      for (const chunk of chunks) {
        combined.set(chunk, offset);
        offset += chunk.byteLength;
      }
      return combined;
    }

    // Fetches and fully validates one image's exact PNG bytes. Throws an
    // `Error` tagged `error.code`: `'not-found'` only for an exact HTTP 404
    // (permanently cacheable — the host never repurposes an `(imageId,
    // version)` pair), `'transient'` for everything else recoverable (5xx,
    // unexpected content type, oversized/streamed-cap, structurally invalid
    // PNG) so callers apply a bounded cooldown instead of a permanent
    // negative cache entry.
    async function fetchTerminalImageBytes(baseURL, sessionId, imageId, version, signal) {
      const query = new URLSearchParams({
        s: sessionId, i: String(imageId), v: String(version)
      });
      const response = await fetch(`${baseURL}terminal-image?${query.toString()}`, {
        signal,
        credentials: 'same-origin'
      });
      if (response.status === 404) {
        const error = new Error('terminal-image-not-found');
        error.code = 'not-found';
        throw error;
      }
      if (!response.ok) {
        const error = new Error(`terminal-image-http-${response.status}`);
        error.code = 'transient';
        throw error;
      }
      const contentType = (response.headers?.get?.('content-type') || '').toLowerCase();
      if (contentType && !contentType.startsWith('image/png')) {
        const error = new Error('terminal-image-unexpected-content-type');
        error.code = 'transient';
        throw error;
      }
      let bytes;
      try {
        bytes = await readBoundedTerminalImageBody(response, TERMINAL_IMAGE_MAX_RESPONSE_BYTES);
      } catch {
        const error = new Error('terminal-image-too-large');
        error.code = 'transient';
        throw error;
      }
      const dimensions = validateTerminalImagePngBytes(bytes);
      if (!dimensions) {
        const error = new Error('terminal-image-invalid-png');
        error.code = 'transient';
        throw error;
      }
      return { bytes, width: dimensions.width, height: dimensions.height };
    }
    """#

    // Conversation transcript rendering: the fetch window, the per-turn card
    // cache, and the stale-response gating. Kept in its own slice (like
    // `markdownJavascript`) so it can be exercised directly under Node with a
    // small DOM shim instead of only asserted as source text. It reads the
    // shared client state declared below (`selected`, `viewMode`, `transcript`,
    // the conversation image helpers) — every entry point runs long after those
    // are initialized.
    static let transcriptJavascript = #"""
    // Only the most recent turns are fetched and rendered up front so a long
    // transcript neither ships its whole history on every revision nor freezes
    // the tab building hundreds of markdown-parsed cards in one synchronous
    // pass; "Show earlier" widens the window a bounded batch at a time.
    const TRANSCRIPT_RENDER_LIMIT = 50;
    const TRANSCRIPT_RENDER_STEP = 50;
    // Matches the host's own `?limit=` ceiling (and its per-session snapshot
    // cap), so the window can never grow past what one response can carry.
    const TRANSCRIPT_MAX_RENDER_LIMIT = 200;
    let transcriptRenderLimit = TRANSCRIPT_RENDER_LIMIT;
    // Last transcript snapshot received for the selected session. Renders are
    // skipped entirely while the Conversation pane is hidden, so this is what
    // revealing it renders from. Session-scoped: cleared in
    // resetTranscriptForSession().
    let lastRenderedTranscript = null;
    // `sessionId\u0000turnId` -> {card, signature, imageNodes}. A turn whose
    // rendered content is unchanged keeps its existing DOM — including its
    // already-parsed markdown and its mounted inline images — so a 2Hz revision
    // stream only builds the turns that actually changed. Bounded by the render
    // window: every render evicts the entries it didn't use, so this is never a
    // growing global memo.
    const transcriptCardCache = new Map();
    // Scroll anchor captured when "Show earlier" is clicked, so the widened
    // window lands on the same content even though the older turns arrive from a
    // later fetch (and even if a revision renders in between).
    let pendingTranscriptAnchor = null;
    // The "Show earlier" control is created once and updated in place (label,
    // disabled state, and the action for the current render), so re-rendering
    // while it holds keyboard focus never blurs it out from under the user.
    let transcriptShowEarlier = null;

    function transcriptCardKey(sessionId, turnId) {
      return `${sessionId}\u0000${turnId}`;
    }

    // Everything a card renders, so a cached card is reused only when the next
    // snapshot would have produced identical DOM. Inline images are part of it:
    // a changed/added/removed image ref must rebuild the card (and re-mount its
    // image nodes) rather than silently keep stale pixels.
    function transcriptCardSignature(turn) {
      return JSON.stringify([
        turn.kind || '',
        !!turn.isAborted,
        turn.userContent || '',
        (turn.assistantMessages || []).map((message) => [
          message.id || '', message.content || ''
        ]),
        (turn.tools || []).map((tool) => [
          tool.id || '', tool.name || '', tool.title || '', tool.success ?? null
        ]),
        (Array.isArray(turn.images) ? turn.images : []).map((raw) => {
          const ref = normalizeConversationImageRef(raw);
          return ref ? `${ref.imageId}:${ref.contentVersion}` : 'invalid';
        })
      ]);
    }

    function releaseTranscriptCardEntry(entry) {
      const releasing = entry.imageNodes;
      // Swap the list out first: a release can run reconciliation callbacks, and
      // none of them may see (or re-walk) a list being mutated underneath them.
      entry.imageNodes = [];
      releasing.forEach(releaseConversationImageNode);
    }

    // Drops every cached card and the image references those cards hold. Used
    // whenever the transcript DOM is replaced by something that isn't a render
    // (session switch, hidden pane, error placeholder), so no cache entry is
    // ever left owning a reference to a node that isn't mounted.
    function clearTranscriptCardCache() {
      const releasing = Array.from(transcriptCardCache.values());
      transcriptCardCache.clear();
      transcriptShowEarlier = null;
      releasing.forEach(releaseTranscriptCardEntry);
    }

    // Hides the conversation pane's content: the cached cards, the image
    // references they hold, AND the rendered DOM itself, so a hidden pane never
    // keeps a window's worth of heavy turn cards alive. `lastRenderedTranscript`
    // is deliberately kept — revealing the pane rebuilds from it.
    function clearTranscriptDOM() {
      clearTranscriptCardCache();
      transcript.replaceChildren();
    }

    // Replaces the conversation DOM with a single status line (loading, or a
    // load failure), dropping whatever cards were up.
    function showTranscriptPlaceholder(message) {
      clearTranscriptCardCache();
      const notice = document.createElement('div');
      notice.className = 'transcript-empty';
      notice.textContent = message;
      transcript.replaceChildren(notice);
    }

    // Clears every conversation image node displaying `key` after that entry's
    // bytes were invalidated (a real decode failure). The node stops pointing at
    // a revoked object URL and, crucially, hands back the decoded-pixel budget it
    // was holding — otherwise those pixels stay charged until the owning card
    // happens to change, blocking later images from mounting. Resetting
    // `cacheKey`/`pixels` here also makes a later release a no-op for the budget,
    // so nothing is ever decremented twice.
    function clearConversationImageCacheKey(key) {
      transcriptCardCache.forEach((entry) => entry.imageNodes.forEach((node) => {
        if (node.cacheKey !== key) return;
        terminalActiveDecodedPixels = Math.max(0, terminalActiveDecodedPixels - node.pixels);
        node.cacheKey = null;
        node.pixels = 0;
        delete node.el.dataset.cacheKey;
        node.el.removeAttribute('src');
      }));
    }

    // Session-scoped transcript state: the cached cards (and their image
    // references), the retained snapshot, the pending anchor, and the fetch
    // window. Runs on every selection change, before anything renders for the
    // new session, and bumps the request generation so a response for the
    // previous session can never land on the new one.
    function resetTranscriptForSession() {
      clearTranscriptCardCache();
      lastRenderedTranscript = null;
      pendingTranscriptAnchor = null;
      transcriptRenderLimit = TRANSCRIPT_RENDER_LIMIT;
      transcriptRequestId += 1;
    }

    // How many older turns the host holds beyond the ones it returned. A host
    // that honored `?limit=` reports `totalTurns`; an older host ignores the
    // query and omits the field, in which case nothing was withheld and the
    // whole transcript is trimmed client-side instead.
    function transcriptWithheldTurnCount(snapshot) {
      const returned = snapshot?.turns?.length || 0;
      const total = snapshot?.totalTurns;
      if (!Number.isSafeInteger(total) || total <= returned) return 0;
      return total - returned;
    }

    // First turn card intersecting the viewport top, with its current position,
    // so a re-render can restore the viewport to the same content.
    function transcriptTopAnchor() {
      const containerTop = transcript.getBoundingClientRect().top;
      for (const card of transcript.querySelectorAll('.turn')) {
        const rect = card.getBoundingClientRect();
        if (rect.bottom > containerTop) {
          return { turnId: card.dataset.turnId, top: rect.top };
        }
      }
      return null;
    }

    // The focused element when it lives inside the transcript, so a render can
    // tell whether it is responsible for focus at all. Focus anywhere else (the
    // prompt, the terminal, the tab strip) is never touched.
    function transcriptFocusedElement() {
      const active = document.activeElement;
      if (!active || active === transcript) return null;
      return transcript.contains(active) ? active : null;
    }

    // Reconciles the transcript's children to exactly `desired`, in order,
    // without detaching anything that is already where it belongs. Detaching a
    // reused card — which a `replaceChildren(fragment)` swap does to every card,
    // even unchanged ones — blurs whatever inside it had keyboard focus and
    // drops the browser's layout for it, so a 2Hz revision stream would fight
    // the reader. Removals run first, then one forward pass inserts only nodes
    // that are new or genuinely out of order.
    function reconcileTranscriptChildren(desired) {
      const wanted = new Set(desired);
      Array.from(transcript.children).forEach((child) => {
        if (!wanted.has(child)) child.remove();
      });
      let cursor = transcript.firstElementChild;
      for (const node of desired) {
        if (cursor === node) {
          cursor = cursor.nextElementSibling;
          continue;
        }
        transcript.insertBefore(node, cursor);
      }
    }

    // The reusable "Show earlier" control. `activate` is null once the window is
    // at the host's per-response ceiling: the remaining turns aren't reachable,
    // so the control reports them instead of offering a no-op action.
    function transcriptShowEarlierControl(earlierCount, activate) {
      if (!transcriptShowEarlier) {
        const control = document.createElement('button');
        control.type = 'button';
        control.className = 'show-earlier';
        control.addEventListener('click', () => {
          if (control.activate) control.activate();
        });
        transcriptShowEarlier = control;
      }
      transcriptShowEarlier.activate = activate;
      transcriptShowEarlier.disabled = !activate;
      transcriptShowEarlier.textContent = activate
        ? `Show earlier (${earlierCount} more)`
        : `${earlierCount} earlier turn${earlierCount === 1 ? '' : 's'} not shown`;
      return transcriptShowEarlier;
    }

    function transcriptMessage(label, text, className) {
      const container = document.createElement('div');
      container.className = `message ${className}`;
      const heading = document.createElement('span');
      heading.className = 'message-label';
      heading.textContent = label;
      container.append(heading);
      appendMarkdown(container, text);
      return container;
    }

    // Builds one turn card (and mounts its inline images). Only ever called for
    // a turn whose content differs from the cached card's, so this is the one
    // place markdown is parsed.
    function buildTranscriptCard(sessionId, turn, signature) {
      const card = document.createElement('article');
      card.className = 'turn';
      card.dataset.turnId = turn.id;
      const header = document.createElement('div');
      header.className = 'turn-header';
      const kind = document.createElement('span');
      kind.textContent = turn.kind === 'scheduled'
        ? 'Scheduled' : turn.kind === 'automated' ? 'Automated' : 'You';
      header.append(kind);
      if (turn.isAborted) {
        const stopped = document.createElement('span');
        stopped.className = 'stopped';
        stopped.textContent = 'Stopped';
        header.append(stopped);
      }
      card.append(header);
      if (turn.userContent) {
        card.append(transcriptMessage('You', turn.userContent, 'user'));
      }
      (turn.assistantMessages || []).forEach((message) => {
        card.append(transcriptMessage('Copilot', message.content, 'assistant'));
      });
      if (turn.tools?.length) {
        const tools = document.createElement('div');
        tools.className = 'tools';
        const successful = turn.tools.filter((tool) => tool.success === true).length;
        tools.textContent = `${turn.tools.length} tool${turn.tools.length === 1 ? '' : 's'}`
          + (successful ? ` · ${successful} completed` : '');
        card.append(tools);
      }
      const imageNodes = [];
      // Renders only run in conversation mode, so mounting here can never hold
      // the shared image budget for a hidden pane.
      if (Array.isArray(turn.images) && turn.images.length && sessionId) {
        const gallery = document.createElement('div');
        gallery.className = 'conversation-images';
        turn.images.forEach((raw) => {
          const ref = normalizeConversationImageRef(raw);
          if (!ref) return;
          const node = createConversationImageNode(sessionId, ref);
          imageNodes.push(node);
          gallery.append(node.figure);
        });
        if (gallery.childElementCount) card.append(gallery);
      }
      return { card, signature, imageNodes };
    }

    function renderTranscript(snapshot) {
      lastRenderedTranscript = snapshot;
      // The Conversation pane is hidden: keep the snapshot, build nothing. The
      // terminal pane is what the user is watching, and revealing this one
      // re-renders from `lastRenderedTranscript` (see setViewMode).
      if (viewMode !== 'conversation') return;
      const sessionId = selected;
      // A "Show earlier" click anchors explicitly; it must win over the
      // stick-to-bottom heuristic so the revealed batch doesn't scroll away.
      const pendingAnchor = pendingTranscriptAnchor;
      pendingTranscriptAnchor = null;
      const wasAtBottom = !pendingAnchor
        && transcript.scrollHeight - transcript.scrollTop - transcript.clientHeight < 18;
      // Capture a stable scroll anchor — the first turn intersecting the viewport
      // top — so trimming older turns (a new SSE turn slides the capped window) or
      // revealing them ("Show earlier") keeps the viewport on the same content
      // instead of jumping. Only needed when the user has scrolled up.
      let anchorId = pendingAnchor?.turnId ?? null;
      let anchorTop = pendingAnchor?.top ?? 0;
      if (!wasAtBottom && anchorId === null) {
        const anchor = transcriptTopAnchor();
        anchorId = anchor?.turnId ?? null;
        anchorTop = anchor?.top ?? 0;
      }
      const desired = [];
      const allTurns = snapshot?.turns || [];
      const total = allTurns.length;
      if (!total) {
        const empty = document.createElement('div');
        empty.className = 'transcript-empty';
        empty.textContent = 'Completed turns will appear here.';
        desired.push(empty);
      }
      // Turns the host withheld because it honored the requested window (zero
      // when an older host ignored `limit` and returned everything).
      const withheld = transcriptWithheldTurnCount(snapshot);
      // Cap the rendered turns to the most recent window; older turns are
      // revealed on demand so a long transcript never builds its whole DOM (and
      // re-parses every message's markdown) in one blocking pass. A host that
      // applied the window already returned exactly this many turns, so this
      // trims nothing; an older host's full transcript is trimmed here.
      const hiddenCount = Math.max(0, total - transcriptRenderLimit);
      const turns = hiddenCount > 0 ? allTurns.slice(hiddenCount) : allTurns;
      const earlierCount = hiddenCount + withheld;
      if (earlierCount > 0) {
        const atCeiling = transcriptRenderLimit >= TRANSCRIPT_MAX_RENDER_LIMIT;
        desired.push(transcriptShowEarlierControl(earlierCount, atCeiling ? null : () => {
          if (transcriptRenderLimit >= TRANSCRIPT_MAX_RENDER_LIMIT) return;
          pendingTranscriptAnchor = transcriptTopAnchor();
          transcriptRenderLimit += TRANSCRIPT_RENDER_STEP;
          if (transcriptRenderLimit > TRANSCRIPT_MAX_RENDER_LIMIT) {
            transcriptRenderLimit = TRANSCRIPT_MAX_RENDER_LIMIT;
          }
          if (withheld > 0 && sessionId) {
            // The older turns were never fetched: widen the request. The
            // currently rendered cards stay up until it resolves.
            fetchTranscript({ sessionId });
          } else {
            renderTranscript(snapshot);
          }
        }));
      } else {
        transcriptShowEarlier = null;
      }
      // Reuse the cached card for every turn whose rendered content is
      // unchanged; only genuinely changed turns are rebuilt.
      const retained = new Map();
      turns.forEach((turn) => {
        const key = transcriptCardKey(sessionId, turn.id);
        const signature = transcriptCardSignature(turn);
        const cached = transcriptCardCache.get(key);
        const entry = cached?.signature === signature
          ? cached
          : buildTranscriptCard(sessionId, turn, signature);
        retained.set(key, entry);
        desired.push(entry.card);
      });
      // Cards replaced by a rebuild, or dropped from the window entirely, are
      // released only after the new DOM (and the replacement image nodes it
      // already mounted) is in place, so an unchanged image's shared cache entry
      // never hits a zero reference count in between.
      const releasing = [];
      transcriptCardCache.forEach((entry, key) => {
        if (retained.get(key) !== entry) releasing.push(entry);
      });
      transcriptCardCache.clear();
      retained.forEach((entry, key) => transcriptCardCache.set(key, entry));
      const focusedBefore = transcriptFocusedElement();
      reconcileTranscriptChildren(desired);
      // Only a genuinely reordered node gets moved, and only such a move can
      // blur focus the transcript owned. Restore it (without scrolling) instead
      // of dropping the reader to the document body; focus is never taken when
      // it wasn't already inside a card that survived this render.
      if (focusedBefore
          && focusedBefore.isConnected
          && document.activeElement !== focusedBefore) {
        focusedBefore.focus({ preventScroll: true });
      }
      releasing.forEach(releaseTranscriptCardEntry);
      if (wasAtBottom) {
        transcript.scrollTop = transcript.scrollHeight;
      } else if (anchorId !== null) {
        // Restore the anchored turn to its prior viewport position.
        let restored = false;
        for (const card of transcript.querySelectorAll('.turn')) {
          if (card.dataset.turnId === anchorId) {
            transcript.scrollTop += card.getBoundingClientRect().top - anchorTop;
            restored = true;
            break;
          }
        }
        // The anchored turn was trimmed off the top (user parked at the very top
        // of an actively-streaming, capped session) — keep them at the top rather
        // than letting the viewport drift by one turn.
        if (!restored) transcript.scrollTop = 0;
      }
    }

    // A response applies only when the selection, the request generation, AND
    // the window it was requested for are all still current: expanding the
    // window or switching sessions must never be overwritten by an in-flight
    // response for the narrower/previous one.
    function transcriptResponseIsCurrent(sessionId, requestId, limit) {
      return selected === sessionId
        && requestId === transcriptRequestId
        && limit === transcriptRenderLimit;
    }

    async function fetchTranscript(revision) {
      const sessionId = revision.sessionId;
      const limit = transcriptRenderLimit;
      const requestId = ++transcriptRequestId;
      try {
        const response = await fetch(
          `${base}transcript?s=${encodeURIComponent(sessionId)}&limit=${limit}`,
          { cache: 'no-store' }
        );
        if (!response.ok
            || !transcriptResponseIsCurrent(sessionId, requestId, limit)) return;
        const snapshot = await response.json();
        if (transcriptResponseIsCurrent(sessionId, requestId, limit)) {
          renderTranscript(snapshot);
        }
      } catch {
        if (transcriptResponseIsCurrent(sessionId, requestId, limit)) {
          showTranscriptPlaceholder('Could not load completed turns.');
        }
      }
    }
    """#

    static let javascript =
        markdownJavascript + draftJavascript + sessionCreationJavascript
        + terminalImageJavascript + transcriptJavascript + #"""
    const sessions = document.querySelector('#sessions');
    const terminal = document.querySelector('#terminal');
    const terminalLines = document.querySelector('#terminal-lines');
    const terminalImageOverlay = document.querySelector('#terminal-image-overlay');
    const terminalCellProbe = document.querySelector('#terminal-cell-probe');
    const connection = document.querySelector('#connection');
    const lease = document.querySelector('#lease');
    const input = document.querySelector('#input');
    const transcript = document.querySelector('#transcript');
    const promptForm = document.querySelector('#prompt-form');
    const prompt = document.querySelector('#prompt');
    const promptStatus = document.querySelector('#prompt-status');
    const promptSubmit = document.querySelector('#prompt-submit');
    const modelLine = document.querySelector('#model-line');
    const modelLineName = document.querySelector('#model-line-name');
    const modelPicker = document.querySelector('#model-picker');
    const modelPickerBody = document.querySelector('#model-picker-body');
    const modelPickerTitle = document.querySelector('#model-picker-title');
    const modelPickerStatus = document.querySelector('#model-picker-status');
    const modelPickerBack = document.querySelector('#model-picker-back');
    const modelPickerClose = document.querySelector('#model-picker-close');
    const userInput = document.querySelector('#user-input');
    const promptQueue = document.querySelector('#prompt-queue');
    const notifications = document.querySelector('#notifications');
    const content = document.querySelector('#content');
    const pivotTabs = Array.from(document.querySelectorAll('.pivot-tab'));
    const newSessionButton = document.querySelector('#new-session');
    const newSessionProject = document.querySelector('#new-session-project');
    const closeSessionButton = document.querySelector('#close-session');
    const createStatus = document.querySelector('#create-status');
    const base = location.pathname.endsWith('/')
      ? location.pathname : `${location.pathname}/`;
    function newUUID() {
      if (globalThis.crypto?.randomUUID) return globalThis.crypto.randomUUID();
      const bytes = new Uint8Array(16);
      if (globalThis.crypto?.getRandomValues) {
        globalThis.crypto.getRandomValues(bytes);
      } else {
        for (let index = 0; index < bytes.length; index += 1) {
          bytes[index] = Math.floor(Math.random() * 256);
        }
      }
      bytes[6] = (bytes[6] & 0x0f) | 0x40;
      bytes[8] = (bytes[8] & 0x3f) | 0x80;
      const hex = Array.from(bytes, (byte) => byte.toString(16).padStart(2, '0'));
      return [
        hex.slice(0, 4).join(''),
        hex.slice(4, 6).join(''),
        hex.slice(6, 8).join(''),
        hex.slice(8, 10).join(''),
        hex.slice(10).join('')
      ].join('-');
    }
    const clientId = newUUID();
    const TOOLBAR_KEYS = {
      'esc': 'escape', 'tab': 'tab', 'enter': 'enter',
      'up': 'up', 'down': 'down'
    };
    let stream = null;
    let selected = null;
    let writable = false;
    let pendingActions = [];
    let flushing = false;
    let lastScreen = null;
    let historyStartLine = 0;
    let historyLines = [];
    // Retained terminal-image placement state: authoritative snapshot from
    // the most recent screen event that included a present `images` array
    // (see buildTerminalImagePlacements), filtered down to whatever's still
    // inside the actually-retained line range after every text update.
    let imagePlacements = [];
    // key -> {el, placement, cacheKey, pixels}. Persistent across renders:
    // `renderLines` never destroys these, only `reconcileImageOverlay` adds/
    // repositions/removes them, keyed by a stable placement identity so an
    // unchanged, still-visible placement's node/img fetch survives.
    const terminalImageNodes = new Map();
    // Conversation-mode inline image nodes are owned solely by the cards in
    // `transcriptCardCache`: a render only
    // releases the nodes of cards it replaced or dropped — after the new DOM is
    // in place — so an unchanged image's shared cache entry never drops to a
    // zero reference count.
    // sessionId:imageId:version -> {url, bytes, width, height, activeNodeCount, lastUsed}
    const terminalImagePositiveCache = new Map();
    // Exact-match permanently-negative keys (404 only). Insertion-ordered Set
    // so the oldest entry can be evicted once the bound is exceeded.
    const terminalImageNegativeCache = new Set();
    // Exact immutable PNG bytes that passed structural validation but the
    // browser decoder rejected. Bounded and permanent for this auth lifetime:
    // re-fetching the same version cannot change the result.
    const terminalImageDecodeFailures = new Set();
    // Images skipped solely because every cache entry was actively visible.
    // These retry only after a real capacity change (node release/eviction),
    // never on a timer that would redownload bytes into the same full cache.
    const terminalImageCapacityBlocked = new Set();
    // key -> {failureCount, nextAttemptAt}: bounded cooldown for transient
    // (non-404) failures, distinct from the permanent negative cache.
    const terminalImageBackoff = new Map();
    const terminalImageRetryTimers = new Map();
    // key -> {controller, promise}
    const terminalImageInFlight = new Map();
    // key -> number of visible nodes waiting to mount a completed cache entry.
    // Eviction treats these entries as active even before `img.src` is set.
    const terminalImagePendingConsumers = new Map();
    // Bumped only on session change/terminal refresh/full auth reset — an
    // ordinary incremental screen update never bumps this, so an in-flight
    // fetch survives an unrelated text-only re-render and reconciles against
    // whatever the current state is once it resolves.
    let terminalImageGeneration = 0;
    let terminalActiveDecodedPixels = 0;
    let terminalImageReconcileScheduled = false;
    let pendingScroll = 0;
    let scrollTimer = null;
    let touchY = null;
    let consecutiveStreamErrors = 0;
    let promptSending = false;
    let awaitingPromptStart = false;
    let promptFallbackTimer = null;
    let transcriptRequestId = 0;
    let selectionGeneration = 0;
    let viewMode = 'conversation';
    // Per-session queue of Copilot prompts. Conversation mode lets you stack
    // multiple messages while the agent is busy; they flush in order as it frees.
    const QUEUE_CAP = 25;
    const promptQueues = new Map();
    let flushingQueue = false;
    // The host selection supplies the initial default only. The web user's explicit
    // project choice is then preserved while that project remains available.
    let hostSelectedProjectId = null;
    let createTargetProjectId = null;
    let availableCreateProjects = [];
    let renderedCreateProjectSignature = null;
    let createRequestId = null;
    let createRequestProjectId = null;
    let creating = false;
    let pendingCreatedSessionId = null;
    const sessionState = new Map();
    // requestId -> card element, and requestId -> { timer, token } while an answer
    // is awaiting confirmation from the workspace snapshot.
    const userInputCards = new Map();
    const submittingUserInputs = new Map();
    const latestUserInputAttempts = new Map();
    let userInputAttemptSequence = 0;
    let userInputCardSequence = 0;
    // Parallel bookkeeping for schema-form / url elicitations. Each entry carries
    // the parsed form and the in-progress answer values so a workspace refresh
    // that doesn't change the request set never wipes a half-filled form.
    const elicitationCards = new Map();
    const submittingElicitations = new Map();
    const latestElicitationAttempts = new Map();
    let elicitationAttemptSequence = 0;
    let elicitationCardSequence = 0;
    const requested = new URLSearchParams(location.search);
    let pendingFocusSession = requested.get('session');

    function setConnection(state, label) {
      connection.className = `connection ${state}`;
      connection.setAttribute('aria-label', label);
      connection.title = label;
      connection.querySelector('.visually-hidden').textContent = label;
    }

    // Mirror the iOS session pivot: show one pane at a time. While the terminal
    // is hidden we skip rendering incoming screen frames entirely; activating the
    // Terminal tab reopens the stream so the gateway resends a fresh snapshot.
    function refreshTerminal() {
      lastScreen = null;
      historyStartLine = 0;
      historyLines = [];
      pendingScroll = 0;
      clearTimeout(scrollTimer);
      scrollTimer = null;
      terminal.classList.remove('terminal-scroll');
      terminalLines.textContent = selected ? 'Loading…' : 'Select a session';
      resetTerminalImagesForSessionChange();
      if (selected) openStream();
    }
    function setViewMode(mode, options) {
      if (mode !== 'terminal' && mode !== 'conversation') return;
      const changed = viewMode !== mode;
      if (changed && mode === 'terminal') {
        const atBottom = transcript.scrollHeight - transcript.scrollTop - transcript.clientHeight < 18;
        pendingTranscriptAnchor = atBottom ? null : transcriptTopAnchor();
      }
      viewMode = mode;
      content.dataset.mode = mode;
      pivotTabs.forEach((tab) => {
        tab.setAttribute('aria-selected', String(tab.dataset.mode === mode));
      });
      if (mode === 'terminal') {
        if (changed) {
          // Free the shared image budget the (now-hidden) conversation images
          // were holding so they can't starve the terminal overlay, and drop the
          // hidden pane's turn cards entirely — a window's worth of markdown DOM
          // must not stay alive behind the terminal.
          clearTranscriptDOM();
          refreshTerminal();
        }
        if (!options?.silent) terminal.focus();
      } else if (mode === 'conversation' && changed) {
        // Nothing was built (or kept) while the pane was hidden, so render fresh
        // from the retained snapshot — or restore the loading notice if no
        // snapshot has arrived for this session yet.
        if (lastRenderedTranscript) renderTranscript(lastRenderedTranscript);
        else if (selected) showTranscriptPlaceholder('Loading completed turns…');
      }
    }

    function openStream() {
      if (stream) stream.close();
      const query = new URLSearchParams();
      if (selected) query.set('s', selected);
      const suffix = query.toString() ? `?${query.toString()}` : '';
      setConnection('connecting', 'Connecting');
      stream = new EventSource(`${base}events${suffix}`);
      stream.onopen = () => {
        consecutiveStreamErrors = 0;
        setConnection('connected', 'Connected');
      };
      stream.onerror = () => {
        consecutiveStreamErrors += 1;
        setConnection('connecting', 'Reconnecting');
        if (consecutiveStreamErrors === 3) {
          const now = Date.now();
          const lastReload = Number(
            sessionStorage.getItem('copilot-projects-auth-reload') || 0
          );
          if (now - lastReload > 60_000) {
            sessionStorage.setItem('copilot-projects-auth-reload', String(now));
            resetTerminalImagesForSignOut();
            setTimeout(() => location.reload(), 1000);
          }
        }
      };
      stream.onmessage = onMessage;
    }
    async function control(message) {
      try {
        return await fetch(`${base}control`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ clientId, ...message })
        });
      } catch (error) {
        setConnection('error', 'Connection error');
        return null;
      }
    }
    let closingSession = false;
    // The close button targets the selected session, which the client already
    // holds the lease for (selectSession acquires it). The gateway rejects a
    // close without a held lease, so gating on `writable` matches the server.
    function updateCloseSessionState() {
      const canClose = !!selected && writable && sessionState.has(selected);
      closeSessionButton.disabled = !canClose || closingSession;
    }
    async function closeCurrentSession() {
      if (!selected || !writable || closingSession) return;
      const sessionId = selected;
      closingSession = true;
      updateCloseSessionState();
      try {
        const response = await control({ type: 'close-session', sessionId });
        if (response && response.ok && selected === sessionId) {
          // The session is ending; drop local control now. The next workspace
          // snapshot removes the tab and reconciles selection.
          writable = false;
          lease.textContent = 'view only';
        }
      } finally {
        closingSession = false;
        updateCloseSessionState();
        updatePromptState();
      }
    }
    function setCreateStatus(text) {
      createStatus.textContent = text || '';
    }
    function updateNewSessionState() {
      newSessionButton.disabled = !createTargetProjectId || creating;
      newSessionProject.disabled = !availableCreateProjects.length || creating;
    }
    function clearCreateRequest() {
      createRequestId = null;
      createRequestProjectId = null;
    }
    function syncCreateProjectOptions(projects, selectedProjectId) {
      availableCreateProjects = projects.map((project) => ({
        id: project.id,
        name: project.name
      }));
      const signature = createProjectSignature(availableCreateProjects);
      if (signature !== renderedCreateProjectSignature) {
        const fragment = document.createDocumentFragment();
        availableCreateProjects.forEach((project) => {
          const option = document.createElement('option');
          option.value = project.id;
          option.textContent = project.name;
          fragment.append(option);
        });
        newSessionProject.replaceChildren(fragment);
        renderedCreateProjectSignature = signature;
      }

      if (!creating) {
        const previousTarget = createTargetProjectId;
        createTargetProjectId = chooseCreateProjectId(
          availableCreateProjects,
          createTargetProjectId,
          selectedProjectId
        );
        if (previousTarget !== createTargetProjectId) {
          if (createRequestProjectId !== createTargetProjectId) {
            clearCreateRequest();
          }
          setCreateStatus('');
        }
      }
      const selectValue = createTargetProjectId || '';
      if (newSessionProject.value !== selectValue) {
        newSessionProject.value = selectValue;
      }
      updateNewSessionState();
    }
    async function createSession() {
      // A double click is blocked while a request is active, and the button stays
      // disabled without a web-selected project.
      const projectId = createTargetProjectId;
      if (creating || !projectId) return;
      // Retain one request id across retries so a network/5xx retry is idempotent.
      if (!createRequestId || createRequestProjectId !== projectId) {
        createRequestId = newUUID();
        createRequestProjectId = projectId;
      }
      creating = true;
      updateNewSessionState();
      setCreateStatus('Creating session…');
      let response;
      try {
        response = await fetch(`${base}sessions/create`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ requestId: createRequestId, projectId })
        });
      } catch (error) {
        // Network failure: keep the request id so a retry reuses it.
        creating = false;
        syncCreateProjectOptions(availableCreateProjects, hostSelectedProjectId);
        setCreateStatus('Network error — tap New Session to retry');
        return;
      }
      creating = false;
      syncCreateProjectOptions(availableCreateProjects, hostSelectedProjectId);
      if (response.status >= 500) {
        // 5xx (incl. 503 Copilot unavailable): retain the id for an idempotent retry.
        setCreateStatus(
          response.status === 503
            ? 'Copilot is unavailable — tap to retry'
            : 'Host error — tap New Session to retry'
        );
        return;
      }
      if (response.status === 410) {
        // Processed-but-closed: a new explicit click should be a new attempt.
        clearCreateRequest();
        setCreateStatus('That session was already created and closed');
        return;
      }
      if (response.status === 404) {
        clearCreateRequest();
        setCreateStatus('New sessions are not supported by this host');
        return;
      }
      if (response.status === 409) {
        clearCreateRequest();
        setCreateStatus('That session id is already in use');
        return;
      }
      if (response.status === 422) {
        clearCreateRequest();
        setCreateStatus('Cannot create a session (no project or Repos unavailable)');
        return;
      }
      if (!response.ok) {
        clearCreateRequest();
        setCreateStatus('Could not create a session');
        return;
      }
      let payload = null;
      try { payload = await response.json(); } catch (error) { payload = null; }
      // On success clear the request id and remember the created session so it can be
      // selected once the workspace snapshot includes it. Host Mac selection is left
      // untouched.
      clearCreateRequest();
      if (payload && payload.sessionId) {
        pendingCreatedSessionId = payload.sessionId;
        setCreateStatus('Session ready');
        if (sessionState.has(pendingCreatedSessionId)) {
          const sessionId = pendingCreatedSessionId;
          pendingCreatedSessionId = null;
          selectSession(sessionId);
        }
      } else {
        setCreateStatus('Session ready');
      }
    }
    async function acquire(id) {
      const response = await control({ type: 'acquire', sessionId: id });
      if (selected !== id) return;
      if (response && response.ok) {
        writable = true;
        lease.textContent = 'control enabled';
        syncUserInputCards();
        syncElicitationCards();
        updatePromptState();
      }
    }
    // Keep the selected session in the URL so a refresh restores it. The
    // initial ?session= param is read into pendingFocusSession on load and
    // applied by renderWorkspace once the session is present.
    function rememberSelectedSession(id) {
      try {
        const url = new URL(location.href);
        if (id) url.searchParams.set('session', id);
        else url.searchParams.delete('session');
        history.replaceState(history.state, '', url);
      } catch (_) {}
    }
    function selectSession(id) {
      const previousSession = selected;
      // Only resave the outgoing draft while that session is still part of
      // the current workspace snapshot. If it was removed since it was
      // selected, prunePromptDrafts() already deleted it; resaving it here
      // would undo that prune with a stale textarea value.
      if (previousSession && sessionState.has(previousSession)) {
        setPromptDraft(previousSession, prompt.value);
        persistPromptDrafts();
      }
      selected = id;
      rememberSelectedSession(id);
      prompt.value = draftForSession(id);
      writable = false;
      pendingActions.length = 0;
      pendingScroll = 0;
      lastScreen = null;
      historyStartLine = 0;
      historyLines = [];
      promptSending = false;
      awaitingPromptStart = false;
      resetTranscriptForSession();
      selectionGeneration += 1;
      clearTimeout(promptFallbackTimer);
      promptFallbackTimer = null;
      clearTimeout(scrollTimer);
      scrollTimer = null;
      resetUserInputCards();
      resetElicitationCards();
      lease.textContent = 'view only';
      terminalLines.textContent = 'Loading…';
      resetTerminalImagesForSessionChange();
      showTranscriptPlaceholder('Loading completed turns…');
      terminal.classList.remove('terminal-scroll');
      document.querySelectorAll('nav button').forEach((button) => {
        button.classList.toggle('active', button.dataset.id === id);
      });
      openStream();
      acquire(id);
      if (viewMode === 'terminal') terminal.focus();
      syncUserInputCards();
      syncElicitationCards();
      renderQueue();
      updatePromptState();
    }
    // Buffer keystrokes and send them in order, one request in flight at a time,
    // so rapid typing can't arrive out of order over HTTP/2.
    function sendInput(data) {
      if (!selected || !writable || !data) return;
      const last = pendingActions.at(-1);
      if (last?.type === 'input') last.data += data;
      else pendingActions.push({type:'input', data});
      flushInput();
    }
    function sendKey(key) {
      if (!selected || !writable || !key) return;
      pendingActions.push({type:'key', data:key});
      flushInput();
    }
    async function flushInput() {
      if (flushing || !pendingActions.length) return;
      flushing = true;
      try {
        while (writable && pendingActions.length) {
          const sessionId = selected;
          const action = pendingActions.shift();
          const response = await control({
            type: action.type,
            sessionId,
            data: action.data
          });
          if (!response) {
            if (selected === sessionId && writable) {
              pendingActions.unshift(action);
              setTimeout(flushInput, 1000);
            }
            return;
          }
          if (response.status === 403) {
            writable = false;
            pendingActions.length = 0;
            lease.textContent = 'view only';
            updatePromptState();
            break;
          }
        }
      } finally {
        flushing = false;
      }
    }
    function sessionQueue(id, create) {
      let q = promptQueues.get(id);
      if (!q && create) { q = []; promptQueues.set(id, q); }
      return q || [];
    }
    function renderQueue() {
      const q = selected ? sessionQueue(selected) : [];
      promptQueue.replaceChildren();
      promptQueue.hidden = q.length === 0;
      q.forEach((message, index) => {
        const item = document.createElement('div');
        item.className = 'queue-item';
        item.setAttribute('role', 'listitem');
        const text = document.createElement('span');
        text.className = 'queue-text';
        text.textContent = message;
        const remove = document.createElement('button');
        remove.type = 'button';
        remove.className = 'queue-remove';
        remove.setAttribute('aria-label', 'Remove queued message');
        remove.textContent = '✕';
        remove.onclick = () => {
          sessionQueue(selected).splice(index, 1);
          renderQueue();
          updatePromptState();
        };
        item.append(text, remove);
        promptQueue.append(item);
      });
    }
    function enqueuePrompt(value) {
      if (!value.trim() || !selected || !writable) return false;
      // A session pruned from the workspace snapshot can no longer flush a
      // queued prompt (flushQueue requires a live sessionState entry), so
      // reject here instead of silently swallowing the message into a queue
      // that will never send - the composer keeps the typed text instead.
      if (!sessionState.has(selected)) return false;
      if (new TextEncoder().encode(value).length > 8192) {
        updatePromptState('Message is too large (8 KB maximum)');
        return false;
      }
      const q = sessionQueue(selected, true);
      if (q.length >= QUEUE_CAP) {
        updatePromptState(`Queue is full (${QUEUE_CAP} max)`);
        return false;
      }
      q.push(value);
      renderQueue();
      updatePromptState();
      return true;
    }
    // Send the head of the selected session's queue when Copilot is idle, then
    // wait for the turn to land before releasing the next one.
    async function flushQueue() {
      if (flushingQueue) return;
      const id = selected;
      if (!id) return;
      const q = promptQueues.get(id);
      if (!q || !q.length) return;
      const state = sessionState.get(id);
      if ((state?.pendingUserInputs || []).length > 0) return;
      if ((state?.pendingElicitations || []).length > 0) return;
      if (!(writable && state?.promptable === true
          && !promptSending && !awaitingPromptStart)) return;
      flushingQueue = true;
      try {
        const value = q[0];
        const submittedGeneration = selectionGeneration;
        promptSending = true;
        promptStatus.textContent = 'Sending…';
        const response = await control({ type: 'prompt', sessionId: id, data: value });
        promptSending = false;
        if (selected !== id || selectionGeneration !== submittedGeneration) return;
        if (response?.ok) {
          if (q[0] === value) q.shift();
          renderQueue();
          awaitingPromptStart = true;
          clearTimeout(promptFallbackTimer);
          promptFallbackTimer = setTimeout(() => {
            awaitingPromptStart = false;
            promptFallbackTimer = null;
            updatePromptState();
          }, 5000);
          updatePromptState();
        } else if (response?.status === 403) {
          writable = false;
          lease.textContent = 'view only';
          updatePromptState('Control moved to another device');
        } else if (response?.status === 409) {
          // Copilot is still working; keep queued and retry shortly.
          updatePromptState('Copilot is still working');
          setTimeout(flushQueue, 3000);
        } else if (response?.status === 422) {
          // Not ready in this terminal; keep queued and retry shortly.
          updatePromptState('Copilot is not ready in this terminal');
          setTimeout(flushQueue, 3000);
        } else {
          // Network or unexpected error: keep queued and retry shortly.
          updatePromptState('Message not sent — will retry');
          setTimeout(flushQueue, 3000);
        }
      } finally {
        flushingQueue = false;
      }
    }
    // ---- Model picker -------------------------------------------------------
    // The composer line shows only the model name; the picker spells out the full
    // selection and drives `set-model` over the same lease-gated /control route
    // the native clients use.
    let modelPickerModelId = null;
    let modelSwitchSubmitting = false;

    function currentModelInfo() {
      const state = selected && sessionState.get(selected);
      return (state && state.model) || null;
    }
    function availableModelOptions() {
      const state = selected && sessionState.get(selected);
      return (state && Array.isArray(state.availableModels)) ? state.availableModels : [];
    }
    function effortLabel(model) {
      const effort = model && model.reasoningEffort;
      if (!effort) return 'Default';
      return effort.charAt(0).toUpperCase() + effort.slice(1);
    }
    function contextLabel(model) {
      return model && model.contextTier === 'long_context' ? 'Long context' : 'Default';
    }
    // The session reports its active model as either the id or the display name.
    function isCurrentModel(model) {
      const current = currentModelInfo();
      if (!current || !current.name) return false;
      return current.name === model.id || current.name === model.name;
    }
    function modelSwitchErrorMessage(status) {
      if (status === 403) return 'View only';
      if (status === 409) return 'Another model switch is still processing';
      if (status === 422) return 'Model switch was not accepted';
      return 'Model switch failed';
    }
    // Never fall back to the first advertised level: several models list "none"
    // first, so that would silently disable reasoning. Keep the session's current
    // level when re-configuring the active model, otherwise defer to Copilot.
    function initialEffort(model) {
      const supported = Array.isArray(model.supportedReasoningEfforts)
        ? model.supportedReasoningEfforts : [];
      const current = isCurrentModel(model)
        ? (currentModelInfo() || {}).reasoningEffort : null;
      return [current, model.defaultReasoningEffort]
        .find((value) => !!value && supported.includes(value)) || '';
    }
    // Category order mirrors the CLI picker's tabs; unknown/absent categories fall
    // into a trailing "Other" group, preserving preferred-first order within each.
    function modelSections(options) {
      const order = ['powerful', 'versatile', 'lightweight'];
      const titles = {
        powerful: 'Powerful', versatile: 'Versatile', lightweight: 'Lightweight'
      };
      const grouped = new Map();
      const seen = [];
      for (const model of options) {
        const key = order.includes(model.category) ? model.category : 'other';
        if (!grouped.has(key)) { grouped.set(key, []); seen.push(key); }
        grouped.get(key).push(model);
      }
      if (seen.length === 1 && seen[0] === 'other') {
        return [{ title: '', models: grouped.get('other') }];
      }
      const ordered = order.filter((key) => grouped.has(key))
        .concat(seen.filter((key) => !order.includes(key)));
      return ordered.map((key) => ({
        title: titles[key] || 'Other', models: grouped.get(key)
      }));
    }

    function renderModelLine() {
      const model = currentModelInfo();
      const name = (model && model.name) || '';
      const interactive = availableModelOptions().length > 0;
      modelLine.hidden = !name;
      if (!name) {
        if (modelPicker.open) closeModelPicker();
        return;
      }
      modelLineName.textContent = name;
      modelLine.dataset.interactive = interactive ? 'true' : 'false';
      modelLine.disabled = !interactive;
      const summary = [name, model.reasoningEffort]
        .filter(Boolean)
        .concat(model.contextTier === 'long_context' ? ['long context'] : [])
        .join(' \u00b7 ');
      // Screen-reader users can't glance at the sheet, so keep the full state here.
      modelLine.setAttribute(
        'aria-label',
        interactive ? `Model ${summary}. Change model` : `Model ${summary}`
      );
      if (modelPicker.open) renderModelPicker();
    }

    function setModelPickerStatus(message, isError) {
      modelPickerStatus.textContent = message || '';
      modelPickerStatus.classList.toggle('error', !!isError && !!message);
    }

    function modelCurrentSummary() {
      const current = currentModelInfo();
      if (!current || !current.name) return null;
      const list = document.createElement('dl');
      list.className = 'model-current';
      for (const [label, value] of [
        ['Model', current.name],
        ['Reasoning effort', effortLabel(current)],
        ['Context', contextLabel(current)]
      ]) {
        const row = document.createElement('div');
        row.className = 'model-current-row';
        const dt = document.createElement('dt');
        dt.textContent = label;
        const dd = document.createElement('dd');
        dd.textContent = value;
        row.append(dt, dd);
        list.append(row);
      }
      return list;
    }

    function renderModelList() {
      modelPickerModelId = null;
      modelPickerTitle.textContent = 'Model';
      modelPickerBack.hidden = true;
      modelPickerBody.replaceChildren();
      const summary = modelCurrentSummary();
      if (summary) {
        const heading = document.createElement('div');
        heading.className = 'model-group-title';
        heading.textContent = 'Current';
        modelPickerBody.append(heading, summary);
      }
      for (const section of modelSections(availableModelOptions())) {
        if (section.title) {
          const heading = document.createElement('div');
          heading.className = 'model-group-title';
          heading.textContent = section.title;
          modelPickerBody.append(heading);
        }
        for (const model of section.models) {
          const row = document.createElement('button');
          row.type = 'button';
          row.className = 'model-row';
          row.disabled = model.disabled === true || !writable;
          const name = document.createElement('span');
          name.className = 'model-row-name';
          name.textContent = model.name;
          row.append(name);
          if (model.disabled === true) {
            const note = document.createElement('span');
            note.className = 'model-row-note';
            note.textContent = 'Unavailable';
            row.append(note);
          }
          if (isCurrentModel(model)) {
            const check = document.createElement('span');
            check.className = 'model-row-check';
            check.textContent = '\u2713';
            check.setAttribute('aria-label', 'Current model');
            row.append(check);
          }
          row.onclick = () => renderModelOptions(model);
          modelPickerBody.append(row);
        }
      }
      setModelPickerStatus(writable ? '' : 'View only \u2014 control is on another device');
    }

    function renderModelOptions(model) {
      modelPickerModelId = model.id;
      modelPickerTitle.textContent = model.name;
      modelPickerBack.hidden = false;
      modelPickerBody.replaceChildren();

      const efforts = Array.isArray(model.supportedReasoningEfforts)
        ? model.supportedReasoningEfforts : [];
      let effortSelect = null;
      if (efforts.length) {
        const field = document.createElement('div');
        field.className = 'model-field';
        const label = document.createElement('label');
        label.textContent = 'Reasoning effort';
        label.htmlFor = 'model-effort';
        effortSelect = document.createElement('select');
        effortSelect.id = 'model-effort';
        const fallback = document.createElement('option');
        fallback.value = '';
        fallback.textContent = 'Default';
        effortSelect.append(fallback);
        for (const level of efforts) {
          const option = document.createElement('option');
          option.value = level;
          option.textContent = level.charAt(0).toUpperCase() + level.slice(1);
          effortSelect.append(option);
        }
        effortSelect.value = initialEffort(model);
        const hint = document.createElement('div');
        hint.className = 'model-hint';
        hint.textContent = "Default lets Copilot pick the model's usual level.";
        field.append(label, effortSelect, hint);
        modelPickerBody.append(field);
      }

      let longContext = null;
      if (model.longContextAvailable === true) {
        const field = document.createElement('div');
        field.className = 'model-field';
        const toggle = document.createElement('label');
        toggle.className = 'model-toggle';
        longContext = document.createElement('input');
        longContext.type = 'checkbox';
        longContext.checked = isCurrentModel(model)
          && (currentModelInfo() || {}).contextTier === 'long_context';
        const text = document.createElement('span');
        text.textContent = 'Long context';
        toggle.append(longContext, text);
        const hint = document.createElement('div');
        hint.className = 'model-hint';
        hint.textContent = 'Accept larger inputs at long-context pricing.';
        field.append(toggle, hint);
        modelPickerBody.append(field);
      }

      const apply = document.createElement('button');
      apply.type = 'button';
      apply.className = 'model-apply';
      apply.textContent = `Switch to ${model.name}`;
      apply.disabled = model.disabled === true || !writable;
      apply.onclick = () => submitModelSwitch(model, {
        reasoningEffort: effortSelect ? (effortSelect.value || null) : null,
        contextTier: longContext ? (longContext.checked ? 'long_context' : 'default') : null
      });
      modelPickerBody.append(apply);
      setModelPickerStatus(writable ? '' : 'View only \u2014 control is on another device');
    }

    function renderModelPicker() {
      if (modelSwitchSubmitting) return;
      const options = availableModelOptions();
      const target = modelPickerModelId
        && options.find((model) => model.id === modelPickerModelId);
      if (target) renderModelOptions(target); else renderModelList();
    }

    async function submitModelSwitch(model, selection) {
      if (modelSwitchSubmitting) return;
      const sessionId = selected;
      if (!sessionId || !writable) return;
      modelSwitchSubmitting = true;
      setModelPickerStatus('Switching\u2026');
      const response = await control({
        type: 'set-model',
        sessionId,
        data: JSON.stringify({
          modelId: model.id,
          reasoningEffort: selection.reasoningEffort,
          contextTier: selection.contextTier
        })
      });
      modelSwitchSubmitting = false;
      if (selected !== sessionId) return;
      if (response && response.ok) {
        closeModelPicker();
        return;
      }
      if (response && response.status === 403) {
        writable = false;
        lease.textContent = 'view only';
        updatePromptState();
      }
      setModelPickerStatus(
        modelSwitchErrorMessage(response ? response.status : 0), true
      );
    }

    function openModelPicker() {
      if (!availableModelOptions().length) return;
      renderModelList();
      if (!modelPicker.open) modelPicker.showModal();
    }
    function closeModelPicker() {
      modelPickerModelId = null;
      setModelPickerStatus('');
      if (modelPicker.open) modelPicker.close();
    }

    modelLine.onclick = openModelPicker;
    modelPickerBack.onclick = () => renderModelList();
    modelPickerClose.onclick = () => closeModelPicker();
    modelPicker.addEventListener('close', () => {
      modelPickerModelId = null;
      setModelPickerStatus('');
    });

    function updatePromptState(message) {
      updateCloseSessionState();
      renderModelLine();
      const state = selected && sessionState.get(selected);
      const pendingInputs = (state && state.pendingUserInputs) || [];
      const pendingElicits = (state && state.pendingElicitations) || [];
      const hasQuestions = pendingInputs.length > 0 || pendingElicits.length > 0;
      promptForm.classList.toggle('hidden', hasQuestions);
      if (hasQuestions) {
        promptSubmit.disabled = true;
        promptStatus.textContent = message || 'Answer Copilot\u2019s question below';
        return;
      }
      if (awaitingPromptStart && state?.promptable === false) {
        awaitingPromptStart = false;
        clearTimeout(promptFallbackTimer);
        promptFallbackTimer = null;
      }
      const q = selected ? (promptQueues.get(selected) || []) : [];
      promptSubmit.disabled = !(selected && writable
        && prompt.value.trim() && q.length < QUEUE_CAP);
      if (message) {
        promptStatus.textContent = message;
      } else if (!selected) {
        promptStatus.textContent = 'Select a Copilot session';
      } else if (!writable) {
        promptStatus.textContent = 'View only';
      } else if (q.length) {
        promptStatus.textContent = `${q.length} queued`;
      } else if (awaitingPromptStart) {
        promptStatus.textContent = 'Sending…';
      } else if (state?.background) {
        promptStatus.textContent = 'Background work active';
      } else if (state?.status === 'waiting') {
        promptStatus.textContent = 'Use the terminal to answer Copilot';
      } else if (state?.status === 'running') {
        promptStatus.textContent = 'Copilot is working';
      } else if (state?.promptable === true) {
        promptStatus.textContent = 'Ready';
      } else {
        promptStatus.textContent = 'Start Copilot in this session';
      }
      flushQueue();
    }
    function renderWorkspace(data) {
      const active = selected;
      const nextProjectId = data.selectedProjectId || null;
      hostSelectedProjectId = nextProjectId;
      syncCreateProjectOptions(data.projects, hostSelectedProjectId);
      sessionState.clear();
      sessions.replaceChildren();
      data.projects.forEach((project) => {
        const heading = document.createElement('h3');
        heading.textContent = project.name;
        sessions.append(heading);
        project.sessions.forEach((session) => {
          sessionState.set(session.id, session);
          const button = document.createElement('button');
          button.dataset.id = session.id;
          button.className = session.id === active ? 'active' : '';
          button.textContent = session.title;
          const detail = document.createElement('small');
          const states = [session.status];
          if (session.background) states.push('background');
          if (session.scheduled) states.push('scheduled');
          if (session.unread) states.push('unread');
          detail.textContent = states.join(' · ');
          button.append(detail);
          button.onclick = () => selectSession(session.id);
          sessions.append(button);
        });
      });
      prunePromptDrafts(new Set(sessionState.keys()));
      updateNewSessionState();
      // Select a just-created session once the host's snapshot includes it, without
      // ever changing the host Mac's own selection.
      if (pendingCreatedSessionId && sessionState.has(pendingCreatedSessionId)) {
        const sessionId = pendingCreatedSessionId;
        pendingCreatedSessionId = null;
        selectSession(sessionId);
      }
      if (pendingFocusSession) {
        const target = document.querySelector(
          `nav button[data-id="${CSS.escape(pendingFocusSession)}"]`
        );
        if (target) {
          const sessionId = pendingFocusSession;
          pendingFocusSession = null;
          selectSession(sessionId);
        }
      }
      syncUserInputCards();
      syncElicitationCards();
      updatePromptState();
    }
    function currentUserInputs() {
      return (selected && sessionState.get(selected)?.pendingUserInputs) || [];
    }
    function sessionHasUserInput(sessionId, requestId) {
      return (sessionState.get(sessionId)?.pendingUserInputs || [])
        .some((request) => request.requestId === requestId);
    }
    function resetUserInputCards() {
      submittingUserInputs.forEach((entry) => clearTimeout(entry.timer));
      submittingUserInputs.clear();
      latestUserInputAttempts.clear();
      userInputCards.clear();
      userInput.replaceChildren();
    }
    function setCardStatus(requestId, text) {
      const status = userInputCards.get(requestId)?.querySelector('.user-input-status');
      if (status) status.textContent = text || '';
    }
    function setCardSubmitting(requestId, submitting) {
      const card = userInputCards.get(requestId);
      if (!card) return;
      card.querySelectorAll('button, textarea').forEach((element) => {
        element.disabled = submitting || !writable;
      });
    }
    function refreshUserInputCardStates() {
      for (const requestId of userInputCards.keys()) {
        setCardSubmitting(requestId, submittingUserInputs.has(requestId));
      }
    }
    // Untrusted question/choice text is only ever inserted with textContent.
    function buildUserInputCard(request) {
      const card = document.createElement('article');
      card.className = 'user-input-card';
      card.dataset.requestId = request.requestId;
      const questionId = `user-input-question-${++userInputCardSequence}`;
      card.setAttribute('aria-labelledby', questionId);
      const head = document.createElement('div');
      head.className = 'user-input-head';
      const heading = document.createElement('span');
      heading.textContent = 'Copilot needs your input';
      head.append(heading);
      if (request.agentId) {
        const agent = document.createElement('span');
        agent.className = 'user-input-agent';
        agent.textContent = 'Subagent';
        head.append(agent);
      }
      card.append(head);
      const question = document.createElement('div');
      question.className = 'user-input-question';
      question.id = questionId;
      question.textContent = request.question;
      card.append(question);
      const choices = Array.isArray(request.choices) ? request.choices : [];
      if (choices.length) {
        const group = document.createElement('div');
        group.className = 'user-input-choices';
        group.setAttribute('role', 'group');
        group.setAttribute('aria-labelledby', questionId);
        choices.forEach((choice) => {
          const button = document.createElement('button');
          button.type = 'button';
          button.className = 'user-input-choice';
          button.textContent = choice;
          button.setAttribute('aria-describedby', questionId);
          button.onclick = () => submitUserInput(request.requestId, choice, false);
          group.append(button);
        });
        card.append(group);
      }
      if (request.allowFreeform) {
        const freeform = document.createElement('form');
        freeform.className = 'user-input-freeform';
        freeform.setAttribute('aria-labelledby', questionId);
        const fieldLabel = document.createElement('span');
        fieldLabel.className = 'visually-hidden';
        fieldLabel.id = `${questionId}-answer-label`;
        fieldLabel.textContent = 'Type an answer';
        const field = document.createElement('textarea');
        field.rows = 2;
        field.maxLength = 8192;
        field.setAttribute('aria-labelledby', `${fieldLabel.id} ${questionId}`);
        field.placeholder = 'Type an answer';
        const submit = document.createElement('button');
        submit.type = 'submit';
        submit.textContent = 'Send answer';
        submit.setAttribute('aria-describedby', questionId);
        freeform.append(fieldLabel, field, submit);
        freeform.onsubmit = (event) => {
          event.preventDefault();
          const value = field.value;
          if (!value.trim()) return;
          submitUserInput(request.requestId, value, true);
        };
        card.append(freeform);
      }
      const status = document.createElement('div');
      status.className = 'user-input-status';
      status.setAttribute('role', 'status');
      status.setAttribute('aria-live', 'polite');
      card.append(status);
      return card;
    }
    // Only rebuild when the set of request IDs changes so a half-typed freeform
    // answer isn't wiped by an unrelated workspace update. A card is removed only
    // once the workspace snapshot no longer includes its request.
    function syncUserInputCards() {
      const pending = currentUserInputs();
      const ids = new Set(pending.map((request) => request.requestId));
      for (const [requestId, card] of [...userInputCards]) {
        if (!ids.has(requestId)) {
          card.remove();
          userInputCards.delete(requestId);
          const entry = submittingUserInputs.get(requestId);
          if (entry) {
            clearTimeout(entry.timer);
            submittingUserInputs.delete(requestId);
          }
          latestUserInputAttempts.delete(requestId);
        }
      }
      pending.forEach((request) => {
        let card = userInputCards.get(request.requestId);
        if (!card) {
          card = buildUserInputCard(request);
          userInputCards.set(request.requestId, card);
          userInput.append(card);
        }
        setCardSubmitting(request.requestId, submittingUserInputs.has(request.requestId));
      });
    }
    async function submitUserInput(requestId, answer, wasFreeform) {
      if (!selected || !writable || submittingUserInputs.has(requestId)) return;
      if (new TextEncoder().encode(answer).length > 8192) {
        setCardStatus(requestId, 'Answer is too large (8 KB maximum)');
        return;
      }
      const submittedSession = selected;
      const submittedGeneration = selectionGeneration;
      const token = ++userInputAttemptSequence;
      latestUserInputAttempts.set(requestId, token);
      // Retryable fallback: if the workspace still shows the question 15s later,
      // re-enable the controls so the answer can be tried again.
      const timer = setTimeout(() => {
        const entry = submittingUserInputs.get(requestId);
        if (!entry || entry.token !== token) return;
        submittingUserInputs.delete(requestId);
        if (selected === submittedSession
            && sessionHasUserInput(submittedSession, requestId)) {
          setCardSubmitting(requestId, false);
          setCardStatus(requestId, 'Still waiting \u2014 you can try again.');
        }
      }, 15000);
      submittingUserInputs.set(requestId, { timer, token });
      setCardSubmitting(requestId, true);
      setCardStatus(requestId, 'Sending\u2026');
      const response = await control({
        type: 'answer-user-input',
        sessionId: submittedSession,
        data: JSON.stringify({ requestId, answer, wasFreeform })
      });
      if (selected !== submittedSession
          || selectionGeneration !== submittedGeneration) return;
      if (latestUserInputAttempts.get(requestId) !== token) return;
      if (response?.ok) {
        // Keep the card disabled until the workspace snapshot drops the request
        // (card removed) or the 15s fallback re-enables it.
        setCardStatus(requestId, 'Waiting for Copilot\u2026');
        return;
      }
      const entry = submittingUserInputs.get(requestId);
      if (entry?.token === token) {
        clearTimeout(entry.timer);
        submittingUserInputs.delete(requestId);
      }
      setCardSubmitting(requestId, false);
      if (response?.status === 403) {
        writable = false;
        lease.textContent = 'view only';
        refreshUserInputCardStates();
        setCardStatus(requestId, 'Control moved to another device');
      } else if (response?.status === 409) {
        setCardStatus(requestId, 'Another answer is still processing — try again.');
      } else if (response?.status === 422) {
        setCardStatus(requestId, 'Answer was not accepted');
      } else {
        setCardStatus(requestId, 'Answer was not sent');
      }
    }
    // ---- Schema-form / url elicitations (elicitation.requested) --------------
    // Mirrors the iOS ElicitationForm/ElicitationCard: only a bounded, flat subset
    // of JSON Schema is rendered natively; anything outside it falls back to the
    // terminal so we never render arbitrary or nested schema.
    const ELICITATION_MAX_FIELDS = 32;
    const ELICITATION_MAX_CHOICES = 50;
    function isPlainObject(value) {
      return value !== null && typeof value === 'object' && !Array.isArray(value);
    }
    function nonNegativeInt(value) {
      if (typeof value !== 'number' || !Number.isFinite(value)
        || value < 0 || !Number.isInteger(value)) {
        return null;
      }
      return value;
    }
    function labeledElicitationChoices(entries) {
      if (!Array.isArray(entries) || entries.length > ELICITATION_MAX_CHOICES) return null;
      const choices = [];
      const seen = new Set();
      for (const entry of entries) {
        if (!isPlainObject(entry)) return null;
        if (!Object.keys(entry).every((key) => key === 'const' || key === 'title')) return null;
        if (typeof entry.const !== 'string' || seen.has(entry.const)) return null;
        seen.add(entry.const);
        let title = entry.const;
        if ('title' in entry) {
          if (typeof entry.title !== 'string') return null;
          title = entry.title;
        }
        choices.push({ value: entry.const, title });
      }
      return choices.length ? choices : null;
    }
    function bareElicitationChoices(values) {
      if (!Array.isArray(values) || values.length > ELICITATION_MAX_CHOICES) return null;
      const choices = [];
      const seen = new Set();
      for (const entry of values) {
        if (typeof entry !== 'string' || seen.has(entry)) return null;
        seen.add(entry);
        choices.push({ value: entry, title: entry });
      }
      return choices.length ? choices : null;
    }
    function elicitationChoiceSet(items) {
      const supportedItemKeys = new Set([
        'anyOf', 'oneOf', 'enum', 'type', 'title', 'description'
      ]);
      if (!Object.keys(items).every((key) => supportedItemKeys.has(key))) return null;
      if ('type' in items && items.type !== 'string') return null;
      const alternatives = Array.isArray(items.anyOf) ? items.anyOf
        : Array.isArray(items.oneOf) ? items.oneOf : null;
      if (alternatives) {
        if ('enum' in items) return null;
        return labeledElicitationChoices(alternatives);
      }
      if (Array.isArray(items.enum)) return bareElicitationChoices(items.enum);
      return null;
    }
    function elicitationStringKind(prop) {
      let minLength = null;
      if ('minLength' in prop) {
        minLength = nonNegativeInt(prop.minLength);
        if (minLength === null) return null;
      }
      let maxLength = null;
      if ('maxLength' in prop) {
        maxLength = nonNegativeInt(prop.maxLength);
        if (maxLength === null) return null;
      }
      if (minLength !== null && maxLength !== null && minLength > maxLength) return null;
      return { type: 'string', minLength, maxLength };
    }
    function elicitationArrayKind(prop) {
      if (!isPlainObject(prop.items)) return null;
      const choices = elicitationChoiceSet(prop.items);
      if (!choices) return null;
      let minItems = null;
      if ('minItems' in prop) {
        minItems = nonNegativeInt(prop.minItems);
        if (minItems === null) return null;
      }
      let maxItems = null;
      if ('maxItems' in prop) {
        maxItems = nonNegativeInt(prop.maxItems);
        if (maxItems === null) return null;
      }
      if (minItems !== null && maxItems !== null && minItems > maxItems) return null;
      return { type: 'stringMultiSelect', choices, minItems, maxItems };
    }
    function elicitationFieldKind(prop) {
      if ('$ref' in prop) return null;
      const banned = [
        'anyOf', 'allOf', 'not', 'if', 'then', 'else', 'const', 'format', 'pattern',
        'minimum', 'maximum', 'exclusiveMinimum', 'exclusiveMaximum', 'multipleOf'
      ];
      for (const key of banned) {
        if (key in prop) return null;
      }
      if (Array.isArray(prop.oneOf)) {
        if ('enum' in prop) return null;
        if ('minLength' in prop || 'maxLength' in prop) return null;
        if (prop.type !== 'string') return null;
        const choices = labeledElicitationChoices(prop.oneOf);
        return choices ? { type: 'stringOneOf', choices } : null;
      }
      if (Array.isArray(prop.enum)) {
        if ('minLength' in prop || 'maxLength' in prop) return null;
        if (prop.type !== 'string') return null;
        if (prop.enum.length > ELICITATION_MAX_CHOICES) return null;
        const options = [];
        const seen = new Set();
        for (const entry of prop.enum) {
          if (typeof entry !== 'string') return null;
          options.push(entry);
          seen.add(entry);
        }
        if (seen.size !== options.length) return null;
        return options.length ? { type: 'stringEnum', options } : null;
      }
      if (typeof prop.type !== 'string') return null;
      const type = prop.type;
      if (type !== 'string' && ('minLength' in prop || 'maxLength' in prop)) return null;
      switch (type) {
        case 'boolean': return { type: 'bool' };
        case 'integer': return { type: 'number', isInteger: true };
        case 'number': return { type: 'number', isInteger: false };
        case 'string': return elicitationStringKind(prop);
        case 'array': return elicitationArrayKind(prop);
        default: return null;
      }
    }
    function parseElicitationForm(schema) {
      if (!isPlainObject(schema)) return null;
      const supportedRootKeys = new Set([
        '$schema', 'type', 'title', 'description', 'properties', 'required',
        'additionalProperties'
      ]);
      if (!Object.keys(schema).every((key) => supportedRootKeys.has(key))) return null;
      if ('type' in schema && schema.type !== 'object') return null;
      const properties = schema.properties;
      if (!isPlainObject(properties)) return null;
      const propertyKeys = Object.keys(properties);
      if (!propertyKeys.length || propertyKeys.length > ELICITATION_MAX_FIELDS) return null;
      const required = new Set();
      if ('required' in schema) {
        if (!Array.isArray(schema.required)) return null;
        for (const name of schema.required) {
          if (typeof name !== 'string') return null;
          required.add(name);
        }
      }
      for (const name of required) {
        if (!(name in properties)) return null;
      }
      const fields = [];
      // JSON object key order isn't guaranteed across the wire, so sort keys for a
      // stable, deterministic field order (matches the iOS client).
      for (const key of propertyKeys.slice().sort()) {
        const prop = properties[key];
        if (!isPlainObject(prop)) return null;
        const kind = elicitationFieldKind(prop);
        if (!kind) return null;
        const title = typeof prop.title === 'string' ? prop.title : key;
        const description = typeof prop.description === 'string' ? prop.description : null;
        fields.push({
          key, title, description, kind,
          required: required.has(key),
          hasDefault: 'default' in prop,
          defaultValue: 'default' in prop ? prop.default : undefined
        });
      }
      return fields.length ? { fields } : null;
    }
    function terminalDefaultBoolean(request) {
      if (request.mode !== 'terminal-default'
          || !isPlainObject(request.schema)
          || request.schema['x-copilot-projects-terminal-default'] !== true
          || Object.keys(request.schema).length !== 2
          || !isPlainObject(request.schema.properties)) return null;
      const keys = Object.keys(request.schema.properties);
      if (keys.length !== 1) return null;
      const field = request.schema.properties[keys[0]];
      if (!isPlainObject(field)
          || field.type !== 'boolean'
          || typeof field.default !== 'boolean') return null;
      return { key: keys[0], value: field.default };
    }
    function elicitationAccepts(kind, value) {
      switch (kind.type) {
        case 'stringEnum':
          return typeof value === 'string' && kind.options.includes(value);
        case 'stringOneOf':
          return typeof value === 'string'
            && kind.choices.some((choice) => choice.value === value);
        case 'bool':
          return typeof value === 'boolean';
        case 'number':
          if (typeof value !== 'number' || !Number.isFinite(value)) return false;
          return kind.isInteger ? value === Math.round(value) : true;
        case 'string': {
          if (typeof value !== 'string') return false;
          const length = [...value].length;
          if (kind.minLength !== null && length < kind.minLength) return false;
          if (kind.maxLength !== null && length > kind.maxLength) return false;
          return true;
        }
        case 'stringMultiSelect': {
          if (!Array.isArray(value)) return false;
          const seen = new Set();
          for (const item of value) {
            if (typeof item !== 'string') return false;
            if (!kind.choices.some((choice) => choice.value === item)) return false;
            if (seen.has(item)) return false;
            seen.add(item);
          }
          if (kind.minItems !== null && value.length < kind.minItems) return false;
          if (kind.maxItems !== null && value.length > kind.maxItems) return false;
          return true;
        }
        default:
          return false;
      }
    }
    // Build the accepted-answer payload, or null while any present value is invalid
    // or a required field is missing.
    function validatedElicitationContent(form, values, touched) {
      const payload = {};
      for (const field of form.fields) {
        if (!(field.key in values)) {
          if (field.required) return null;
          continue;
        }
        const value = values[field.key];
        if (!elicitationAccepts(field.kind, value)) return null;
        if (field.required || touched.has(field.key) || field.hasDefault) {
          payload[field.key] = value;
        }
      }
      return payload;
    }
    function seedElicitationDefaults(entry) {
      if (!entry.form) return;
      for (const field of entry.form.fields) {
        if (field.hasDefault && elicitationAccepts(field.kind, field.defaultValue)) {
          entry.values[field.key] = field.defaultValue;
        } else if (field.required) {
          switch (field.kind.type) {
            case 'stringEnum':
              if (field.kind.options.length) entry.values[field.key] = field.kind.options[0];
              break;
            case 'stringOneOf':
              if (field.kind.choices.length) {
                entry.values[field.key] = field.kind.choices[0].value;
              }
              break;
            case 'bool':
              entry.values[field.key] = false;
              break;
            case 'string':
              entry.values[field.key] = '';
              break;
            case 'stringMultiSelect':
              entry.values[field.key] = [];
              break;
            case 'number':
              break;  // required numbers must be filled by the user
          }
        }
      }
    }
    function elicitationValuesEqual(a, b) {
      if (a === undefined && b === undefined) return true;
      return a === b;
    }
    function parseElicitationNumber(text) {
      const trimmed = text.trim();
      if (!trimmed) return null;
      if (!/^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?$/.test(trimmed)) return null;
      const value = Number(trimmed);
      return Number.isFinite(value) ? value : null;
    }
    function formatElicitationNumber(value) {
      if (value === Math.round(value) && Math.abs(value) < 1e15) {
        return String(Math.round(value));
      }
      return String(value);
    }
    function elicitationStringLengthRequirement(kind) {
      if (kind.type !== 'string') return null;
      const { minLength, maxLength } = kind;
      if (minLength !== null && maxLength !== null) {
        return `Use ${minLength}\u2013${maxLength} code points.`;
      }
      if (minLength !== null) {
        return `Use at least ${minLength} ${minLength === 1 ? 'code point' : 'code points'}.`;
      }
      if (maxLength !== null) {
        return `Use at most ${maxLength} ${maxLength === 1 ? 'code point' : 'code points'}.`;
      }
      return null;
    }
    function safeWebURL(rawURL) {
      if (typeof rawURL !== 'string' || !rawURL) return null;
      let url;
      try {
        url = new URL(rawURL);
      } catch (error) {
        return null;
      }
      const scheme = url.protocol.toLowerCase();
      if (scheme !== 'https:' && scheme !== 'http:') return null;
      if (!url.host) return null;
      return url.href;
    }
    function currentElicitations() {
      return (selected && sessionState.get(selected)?.pendingElicitations) || [];
    }
    function sessionHasElicitation(sessionId, requestId) {
      return (sessionState.get(sessionId)?.pendingElicitations || [])
        .some((request) => request.requestId === requestId);
    }
    function resetElicitationCards() {
      submittingElicitations.forEach((entry) => clearTimeout(entry.timer));
      submittingElicitations.clear();
      latestElicitationAttempts.clear();
      elicitationCards.clear();
    }
    function setElicitationStatus(requestId, text) {
      const status = elicitationCards.get(requestId)?.card
        .querySelector('.user-input-status');
      if (status) status.textContent = text || '';
    }
    function refreshElicitationControls(entry) {
      const submitting = submittingElicitations.has(entry.request.requestId);
      const disabled = submitting || !writable;
      entry.card.querySelectorAll(
        'select, input, textarea, .elicitation-multi-option, .elicitation-decline'
      ).forEach((element) => { element.disabled = disabled; });
      entry.card.querySelectorAll('.elicitation-multi-option').forEach((button) => {
        button.style.opacity = disabled ? '0.5' : '1';
      });
      if (entry.submitButton) {
        if (entry.isURLMode) {
          entry.submitButton.disabled = disabled;
        } else if (entry.terminalDefault) {
          entry.submitButton.disabled = disabled;
        } else if (entry.form) {
          entry.submitButton.disabled = disabled
            || validatedElicitationContent(entry.form, entry.values, entry.touched) === null;
        }
      }
    }
    function refreshElicitationCardStates() {
      for (const entry of elicitationCards.values()) {
        refreshElicitationControls(entry);
      }
    }
    function selectedMultiStrings(entry, key) {
      const value = entry.values[key];
      if (!Array.isArray(value)) return [];
      return value.filter((item) => typeof item === 'string');
    }
    function toggleElicitationChoice(entry, field, value) {
      const kind = field.kind;
      const selected = new Set(selectedMultiStrings(entry, field.key));
      if (selected.has(value)) {
        selected.delete(value);
      } else {
        if (kind.maxItems !== null && selected.size >= kind.maxItems) return;
        selected.add(value);
      }
      entry.values[field.key] = kind.choices
        .map((choice) => choice.value)
        .filter((choiceValue) => selected.has(choiceValue));
      entry.touched.add(field.key);
    }
    function buildElicitationChoiceSelect(entry, field, controlId, options) {
      const select = document.createElement('select');
      select.id = controlId;
      select.className = 'elicitation-control';
      options.forEach((option) => {
        const element = document.createElement('option');
        element.textContent = option.title;
        select.append(element);
      });
      select.onchange = () => {
        const chosen = options[select.selectedIndex];
        if (chosen.value === undefined) delete entry.values[field.key];
        else entry.values[field.key] = chosen.value;
        entry.touched.add(field.key);
        entry.refresh();
      };
      entry.controlSyncers.push(() => {
        const current = entry.values[field.key];
        let index = options.findIndex((option) =>
          elicitationValuesEqual(option.value, current));
        if (index < 0) index = 0;
        select.selectedIndex = index;
      });
      return select;
    }
    function buildElicitationControl(entry, field, controlId) {
      const kind = field.kind;
      switch (kind.type) {
        case 'stringEnum': {
          const options = kind.options.map((option) =>
            ({ value: option, title: option === '' ? 'Empty string' : option }));
          if (!field.required) options.unshift({ value: undefined, title: 'Not set' });
          return buildElicitationChoiceSelect(entry, field, controlId, options);
        }
        case 'stringOneOf': {
          const options = kind.choices.map((choice) =>
            ({ value: choice.value, title: choice.title }));
          if (!field.required) options.unshift({ value: undefined, title: 'Not set' });
          return buildElicitationChoiceSelect(entry, field, controlId, options);
        }
        case 'bool': {
          if (field.required) {
            const label = document.createElement('label');
            label.className = 'elicitation-check';
            const input = document.createElement('input');
            input.type = 'checkbox';
            input.id = controlId;
            input.onchange = () => {
              entry.values[field.key] = input.checked;
              entry.touched.add(field.key);
              entry.refresh();
            };
            entry.controlSyncers.push(() => {
              input.checked = entry.values[field.key] === true;
            });
            const caption = document.createElement('span');
            caption.textContent = 'Enabled';
            label.append(input, caption);
            return label;
          }
          return buildElicitationChoiceSelect(entry, field, controlId, [
            { value: undefined, title: 'Not set' },
            { value: true, title: 'True' },
            { value: false, title: 'False' }
          ]);
        }
        case 'number': {
          const input = document.createElement('input');
          input.type = 'text';
          input.inputMode = kind.isInteger ? 'numeric' : 'decimal';
          input.id = controlId;
          input.className = 'elicitation-control';
          input.oninput = () => {
            entry.touched.add(field.key);
            const number = parseElicitationNumber(input.value);
            if (number !== null) entry.values[field.key] = number;
            else if (input.value.trim() === '') delete entry.values[field.key];
            // Keep the raw text so the user can keep editing; validation rejects it.
            else entry.values[field.key] = input.value;
            entry.refresh();
          };
          entry.controlSyncers.push(() => {
            const value = entry.values[field.key];
            if (typeof value === 'number' && Number.isFinite(value)) {
              input.value = formatElicitationNumber(value);
            } else if (typeof value === 'string') {
              input.value = value;
            } else {
              input.value = '';
            }
          });
          return input;
        }
        case 'string': {
          const wrap = document.createElement('div');
          const textarea = document.createElement('textarea');
          textarea.id = controlId;
          textarea.className = 'elicitation-control';
          textarea.rows = 2;
          textarea.oninput = () => {
            entry.touched.add(field.key);
            const text = textarea.value;
            if (!field.required && text === '' && !elicitationAccepts(kind, '')) {
              delete entry.values[field.key];
            } else {
              entry.values[field.key] = text;
            }
            entry.refresh();
          };
          entry.controlSyncers.push(() => {
            const value = entry.values[field.key];
            textarea.value = typeof value === 'string' ? value : '';
          });
          wrap.append(textarea);
          const requirement = elicitationStringLengthRequirement(kind);
          if (requirement) {
            const hint = document.createElement('div');
            hint.className = 'elicitation-hint';
            hint.textContent = requirement;
            wrap.append(hint);
          }
          return wrap;
        }
        case 'stringMultiSelect': {
          const group = document.createElement('div');
          group.className = 'elicitation-multi';
          group.setAttribute('role', 'group');
          const syncGroup = () => {
            const selected = new Set(selectedMultiStrings(entry, field.key));
            group.querySelectorAll('.elicitation-multi-option').forEach((button) => {
              const on = selected.has(button.dataset.value);
              button.setAttribute('aria-pressed', on ? 'true' : 'false');
              const box = button.querySelector('.elicitation-multi-box');
              if (box) box.textContent = on ? '\u2611' : '\u2610';
            });
          };
          kind.choices.forEach((choice) => {
            const button = document.createElement('button');
            button.type = 'button';
            button.className = 'elicitation-multi-option';
            button.dataset.value = choice.value;
            button.setAttribute('aria-pressed', 'false');
            const box = document.createElement('span');
            box.className = 'elicitation-multi-box';
            box.setAttribute('aria-hidden', 'true');
            box.textContent = '\u2610';
            const caption = document.createElement('span');
            caption.textContent = choice.title;
            button.append(box, caption);
            button.onclick = () => {
              toggleElicitationChoice(entry, field, choice.value);
              syncGroup();
              entry.refresh();
            };
            group.append(button);
          });
          entry.controlSyncers.push(syncGroup);
          return group;
        }
        default:
          return document.createElement('div');
      }
    }
    function buildElicitationField(entry, field) {
      const wrap = document.createElement('div');
      wrap.className = 'elicitation-field';
      const controlId = `elicitation-field-${++elicitationCardSequence}`;
      const title = document.createElement('label');
      title.className = 'elicitation-field-title';
      title.setAttribute('for', controlId);
      title.textContent = field.title;
      if (field.required) {
        const marker = document.createElement('span');
        marker.className = 'elicitation-field-req';
        marker.textContent = ' *';
        title.append(marker);
      }
      wrap.append(title);
      if (field.description) {
        const description = document.createElement('div');
        description.className = 'elicitation-field-desc';
        description.textContent = field.description;
        wrap.append(description);
      }
      wrap.append(buildElicitationControl(entry, field, controlId));
      return wrap;
    }
    function buildElicitationActions(entry, acceptLabel, includeAccept) {
      const actions = document.createElement('div');
      actions.className = 'elicitation-actions';
      const decline = document.createElement('button');
      decline.type = 'button';
      decline.className = 'elicitation-decline';
      decline.textContent = 'Decline';
      decline.onclick = () => submitElicitation(entry.request.requestId, 'decline');
      actions.append(decline);
      if (includeAccept) {
        const spacer = document.createElement('span');
        spacer.className = 'spacer';
        const accept = document.createElement('button');
        accept.type = 'button';
        accept.className = 'elicitation-submit';
        accept.textContent = acceptLabel;
        accept.onclick = () => submitElicitation(entry.request.requestId, 'accept');
        actions.append(spacer, accept);
        entry.submitButton = accept;
      }
      return actions;
    }
    function buildElicitationURLControls(entry, card) {
      const request = entry.request;
      const link = safeWebURL(request.url);
      if (link) {
        const urlText = document.createElement('div');
        urlText.className = 'elicitation-url';
        urlText.textContent = link;
        card.append(urlText);
        const open = document.createElement('a');
        open.className = 'elicitation-open';
        open.href = link;
        open.target = '_blank';
        open.rel = 'noopener noreferrer';
        open.textContent = 'Open in browser';
        card.append(open);
        card.append(buildElicitationActions(entry, 'Done', true));
      } else {
        const fallback = document.createElement('div');
        fallback.className = 'elicitation-fallback';
        fallback.textContent = 'Open this link in the Copilot terminal.';
        card.append(fallback);
        if (typeof request.url === 'string' && request.url) {
          const raw = document.createElement('div');
          raw.className = 'elicitation-url';
          raw.textContent = request.url;
          card.append(raw);
        }
        card.append(buildElicitationActions(entry, 'Done', false));
      }
    }
    function buildTerminalDefaultControls(entry, card) {
      const fallback = document.createElement('div');
      fallback.className = 'elicitation-fallback';
      fallback.textContent =
        'This question is being handled in the terminal. You can safely accept '
        + 'the highlighted default here or use the terminal for another answer.';
      card.append(fallback);
      const actions = document.createElement('div');
      actions.className = 'elicitation-actions';
      const open = document.createElement('button');
      open.type = 'button';
      open.className = 'elicitation-open';
      open.textContent = 'Open terminal';
      open.onclick = () => setViewMode('terminal');
      const spacer = document.createElement('span');
      spacer.className = 'spacer';
      const accept = document.createElement('button');
      accept.type = 'button';
      accept.className = 'elicitation-submit';
      accept.textContent = `Use default: ${entry.terminalDefault.value ? 'Yes' : 'No'}`;
      accept.onclick = () => submitElicitation(entry.request.requestId, 'accept');
      actions.append(open, spacer, accept);
      card.append(actions);
      entry.submitButton = accept;
    }
    // Untrusted message/field text is only ever inserted with textContent.
    function buildElicitationCard(request) {
      const form = parseElicitationForm(request.schema);
      const entry = {
        request,
        form,
        terminalDefault: terminalDefaultBoolean(request),
        isURLMode: request.mode === 'url'
          || (typeof request.url === 'string' && request.url.length > 0),
        values: {},
        touched: new Set(),
        controlSyncers: [],
        card: null,
        submitButton: null,
        refresh: () => {}
      };
      const card = document.createElement('article');
      card.className = 'user-input-card elicitation-card';
      card.dataset.requestId = request.requestId;
      const messageId = `elicitation-message-${++elicitationCardSequence}`;
      card.setAttribute('aria-labelledby', messageId);
      const head = document.createElement('div');
      head.className = 'user-input-head';
      const heading = document.createElement('span');
      heading.textContent = 'Copilot needs your input';
      head.append(heading);
      if (request.agentId) {
        const agent = document.createElement('span');
        agent.className = 'user-input-agent';
        agent.textContent = 'Subagent';
        head.append(agent);
      }
      card.append(head);
      const message = document.createElement('div');
      message.className = 'user-input-question';
      message.id = messageId;
      message.textContent = request.message || '';
      card.append(message);
      if (entry.isURLMode) {
        buildElicitationURLControls(entry, card);
      } else if (entry.terminalDefault) {
        buildTerminalDefaultControls(entry, card);
      } else if (entry.form) {
        const fields = document.createElement('div');
        fields.className = 'elicitation-fields';
        entry.form.fields.forEach((field) => {
          fields.append(buildElicitationField(entry, field));
        });
        card.append(fields);
        card.append(buildElicitationActions(entry, 'Send answer', true));
      } else {
        // Outside the supported flat-schema subset: keep it answerable in the
        // terminal rather than rendering arbitrary/nested schema.
        const fallback = document.createElement('div');
        fallback.className = 'elicitation-fallback';
        fallback.textContent = 'Answer this one in the Copilot terminal.';
        card.append(fallback);
        const open = document.createElement('button');
        open.type = 'button';
        open.className = 'elicitation-open';
        open.textContent = 'Open terminal';
        open.onclick = () => setViewMode('terminal');
        card.append(open);
      }
      const status = document.createElement('div');
      status.className = 'user-input-status';
      status.setAttribute('role', 'status');
      status.setAttribute('aria-live', 'polite');
      card.append(status);
      entry.card = card;
      entry.refresh = () => refreshElicitationControls(entry);
      if (!entry.isURLMode && entry.form) seedElicitationDefaults(entry);
      entry.controlSyncers.forEach((sync) => sync());
      entry.refresh();
      return entry;
    }
    // Only build a card once per request ID so an in-progress form isn't wiped by
    // an unrelated workspace update; a card is removed only when the snapshot drops
    // its request.
    function syncElicitationCards() {
      const pending = currentElicitations();
      const ids = new Set(pending.map((request) => request.requestId));
      for (const [requestId, entry] of [...elicitationCards]) {
        if (!ids.has(requestId)) {
          entry.card.remove();
          elicitationCards.delete(requestId);
          const submitting = submittingElicitations.get(requestId);
          if (submitting) {
            clearTimeout(submitting.timer);
            submittingElicitations.delete(requestId);
          }
          latestElicitationAttempts.delete(requestId);
        }
      }
      pending.forEach((request) => {
        let entry = elicitationCards.get(request.requestId);
        if (!entry) {
          entry = buildElicitationCard(request);
          elicitationCards.set(request.requestId, entry);
          userInput.append(entry.card);
        }
        entry.refresh();
      });
    }
    async function submitElicitation(requestId, action) {
      if (!selected || !writable || submittingElicitations.has(requestId)) return;
      const entry = elicitationCards.get(requestId);
      if (!entry) return;
      let content = null;
      if (action === 'accept' && entry.terminalDefault) {
        content = {
          [entry.terminalDefault.key]: entry.terminalDefault.value
        };
      } else if (action === 'accept' && entry.form) {
        content = validatedElicitationContent(entry.form, entry.values, entry.touched);
        if (content === null) return;
        let encoded;
        try {
          encoded = JSON.stringify(content);
        } catch (error) {
          setElicitationStatus(requestId, 'Answer was not sent');
          return;
        }
        if (new TextEncoder().encode(encoded).length > 32768) {
          setElicitationStatus(
            requestId, 'Answer is too large to send \u2014 shorten it and try again.'
          );
          return;
        }
      }
      const payload = { requestId, action };
      if (action === 'accept' && content !== null) payload.content = content;
      const submittedSession = selected;
      const submittedGeneration = selectionGeneration;
      const token = ++elicitationAttemptSequence;
      latestElicitationAttempts.set(requestId, token);
      // Retryable fallback: if the workspace still shows the request 15s later,
      // re-enable the controls so the answer can be tried again.
      const timer = setTimeout(() => {
        const submitting = submittingElicitations.get(requestId);
        if (!submitting || submitting.token !== token) return;
        submittingElicitations.delete(requestId);
        if (selected === submittedSession
            && sessionHasElicitation(submittedSession, requestId)) {
          entry.refresh();
          setElicitationStatus(requestId, 'Still waiting \u2014 you can try again.');
        }
      }, 15000);
      submittingElicitations.set(requestId, { timer, token });
      entry.refresh();
      setElicitationStatus(requestId, 'Sending\u2026');
      const response = await control({
        type: 'answer-elicitation',
        sessionId: submittedSession,
        data: JSON.stringify(payload)
      });
      if (selected !== submittedSession
          || selectionGeneration !== submittedGeneration) return;
      if (latestElicitationAttempts.get(requestId) !== token) return;
      if (response?.ok) {
        // Keep the card disabled until the workspace snapshot drops the request
        // (card removed) or the 15s fallback re-enables it.
        setElicitationStatus(requestId, 'Waiting for Copilot\u2026');
        return;
      }
      const submitting = submittingElicitations.get(requestId);
      if (submitting?.token === token) {
        clearTimeout(submitting.timer);
        submittingElicitations.delete(requestId);
      }
      entry.refresh();
      if (response?.status === 403) {
        writable = false;
        lease.textContent = 'view only';
        refreshElicitationCardStates();
        setElicitationStatus(requestId, 'Control moved to another device');
      } else if (response?.status === 409) {
        setElicitationStatus(requestId, 'Another answer is still processing \u2014 try again.');
      } else if (response?.status === 422) {
        setElicitationStatus(requestId, 'Answer was not accepted');
      } else {
        setElicitationStatus(requestId, 'Answer was not sent');
      }
    }
    const LINK_PATTERN = /\[[^\]\r\n]+\]\((https?:\/\/[^\s)]+)\)|https?:\/\/[^\s<>()\[\]]+/gi;
    function appendLinkedText(parent, text) {
      let cursor = 0;
      for (const match of text.matchAll(LINK_PATTERN)) {
        if (match.index > cursor) {
          parent.append(document.createTextNode(text.slice(cursor, match.index)));
        }
        const raw = match[0];
        const href = match[1] || raw;
        let url = null;
        try { url = new URL(href); } catch (_) {}
        if (url && (url.protocol === 'https:' || url.protocol === 'http:')) {
          const anchor = document.createElement('a');
          anchor.className = 'terminal-link';
          anchor.href = url.href;
          anchor.target = '_blank';
          anchor.rel = 'noopener noreferrer';
          anchor.textContent = raw;
          anchor.onclick = (event) => event.stopPropagation();
          parent.append(anchor);
        } else {
          parent.append(document.createTextNode(raw));
        }
        cursor = match.index + raw.length;
      }
      if (cursor < text.length) {
        parent.append(document.createTextNode(text.slice(cursor)));
      }
    }

    // Line height prefers an actually-rendered `.terminal-line` (the real,
    // current font metrics); falls back to the hidden probe (e.g. before any
    // line has ever rendered), then a nonzero hardcoded default so a
    // measurement glitch can never divide-by-zero downstream.
    function measuredLineHeight() {
      const rendered = terminalLines.querySelector('.terminal-line')
        ?.getBoundingClientRect().height;
      if (rendered && rendered > 0) return rendered;
      const probe = terminalCellProbe?.getBoundingClientRect().height;
      if (probe && probe > 0) return probe;
      return 16;
    }
    // Cell width has no equivalent "real rendered line" source (a line's
    // width varies with its content), so it's always measured from the
    // dedicated fixed-length probe.
    const TERMINAL_CELL_PROBE_LENGTH = 32;
    function measuredCellWidth() {
      const rect = terminalCellProbe?.getBoundingClientRect();
      if (rect && rect.width > 0) return rect.width / TERMINAL_CELL_PROBE_LENGTH;
      return 8;
    }

    function terminalImageBackoffActive(key) {
      const entry = terminalImageBackoff.get(key);
      if (!entry || entry.nextAttemptAt <= Date.now()) return false;
      scheduleTerminalImageRetry(key, entry.nextAttemptAt, terminalImageGeneration);
      return true;
    }

    function scheduleTerminalImageRetry(key, nextAttemptAt, generation) {
      clearTimeout(terminalImageRetryTimers.get(key));
      const delay = Math.max(0, nextAttemptAt - Date.now());
      const timer = setTimeout(() => {
        terminalImageRetryTimers.delete(key);
        if (terminalImageGeneration !== generation || !selected) return;
        const stillCurrent = imagePlacements.some((placement) => (
          terminalImageCacheKey(
            selected, placement.imageId, placement.contentVersion
          ) === key
        ));
        if (stillCurrent) scheduleTerminalImageReconcile();
      }, delay);
      terminalImageRetryTimers.set(key, timer);
    }

    function setTerminalImageBackoff(key, failureCount, generation) {
      const nextAttemptAt = Date.now() + terminalImageBackoffDelayMs(failureCount);
      terminalImageBackoff.delete(key);
      terminalImageBackoff.set(key, { failureCount, nextAttemptAt });
      while (terminalImageBackoff.size > TERMINAL_IMAGE_MAX_BACKOFF_ENTRIES) {
        const oldest = terminalImageBackoff.keys().next().value;
        terminalImageBackoff.delete(oldest);
        clearTimeout(terminalImageRetryTimers.get(oldest));
        terminalImageRetryTimers.delete(oldest);
      }
      scheduleTerminalImageRetry(key, nextAttemptAt, generation);
    }

    function terminalImagePositiveCacheBytes() {
      let total = 0;
      terminalImagePositiveCache.forEach((entry) => { total += entry.bytes; });
      return total;
    }

    // Only ever revokes/evicts entries with `activeNodeCount === 0` — an
    // entry currently referenced by a visible `<img>` node is never a
    // candidate, no matter how stale, so eviction can never pull a blob URL
    // out from under something on screen.
    function makeRoomInTerminalImagePositiveCache(extraBytes) {
      const withinBudget = () => (
        terminalImagePositiveCache.size < TERMINAL_IMAGE_MAX_POSITIVE_CACHE_ENTRIES
        && terminalImagePositiveCacheBytes() + extraBytes <= TERMINAL_IMAGE_MAX_POSITIVE_CACHE_BYTES
      );
      if (withinBudget()) return true;
      let evictedAny = false;
      const evictable = [...terminalImagePositiveCache.entries()]
        .filter(([key, entry]) => entry.activeNodeCount === 0
          && (terminalImagePendingConsumers.get(key) || 0) === 0)
        .sort((a, b) => a[1].lastUsed - b[1].lastUsed);
      for (const [key, entry] of evictable) {
        URL.revokeObjectURL(entry.url);
        terminalImagePositiveCache.delete(key);
        evictedAny = true;
        if (withinBudget()) {
          if (evictedAny) retryCapacityBlockedTerminalImages();
          return true;
        }
      }
      if (evictedAny) retryCapacityBlockedTerminalImages();
      return withinBudget();
    }

    function addTerminalImageNegativeCacheEntry(key) {
      terminalImageNegativeCache.delete(key);
      terminalImageNegativeCache.add(key);
      while (terminalImageNegativeCache.size > TERMINAL_IMAGE_MAX_NEGATIVE_CACHE_ENTRIES) {
        const oldest = terminalImageNegativeCache.values().next().value;
        terminalImageNegativeCache.delete(oldest);
      }
    }

    function addBoundedTerminalImageKey(set, key) {
      set.delete(key);
      set.add(key);
      while (set.size > TERMINAL_IMAGE_MAX_NEGATIVE_CACHE_ENTRIES) {
        set.delete(set.values().next().value);
      }
    }

    function blockTerminalImageOnCapacity(key) {
      addBoundedTerminalImageKey(terminalImageCapacityBlocked, key);
    }

    function retryCapacityBlockedTerminalImages() {
      if (!terminalImageCapacityBlocked.size) return;
      terminalImageCapacityBlocked.clear();
      scheduleTerminalImageReconcile();
    }

    // Bounded loader: at most `TERMINAL_IMAGE_MAX_IN_FLIGHT` concurrent
    // requests, a 15s abort timeout, and every terminal outcome (positive,
    // permanent 404, or transient cooldown) recorded so repeated
    // reconciliation passes never refetch something already known-bad this
    // soon. Resolves to the cache entry, or `null` if the image isn't
    // currently available (never rejects).
    function loadTerminalImage(sessionId, placement) {
      const key = terminalImageCacheKey(sessionId, placement.imageId, placement.contentVersion);
      const cached = terminalImagePositiveCache.get(key);
      if (cached) {
        cached.lastUsed = Date.now();
        return Promise.resolve(cached);
      }
      if (terminalImageNegativeCache.has(key)) return Promise.resolve(null);
      if (terminalImageDecodeFailures.has(key)) return Promise.resolve(null);
      if (terminalImageCapacityBlocked.has(key)) return Promise.resolve(null);
      if (terminalImageBackoffActive(key)) return Promise.resolve(null);
      const existing = terminalImageInFlight.get(key);
      if (existing) return existing.promise;
      if (terminalImageInFlight.size >= TERMINAL_IMAGE_MAX_IN_FLIGHT) {
        return Promise.resolve(null);
      }
      if (!makeRoomInTerminalImagePositiveCache(0)) {
        // No cache room and nothing inactive to evict for it: skip the fetch
        // entirely until a node release makes a real entry evictable.
        blockTerminalImageOnCapacity(key);
        return Promise.resolve(null);
      }
      const controller = new AbortController();
      const timeoutId = setTimeout(() => controller.abort(), TERMINAL_IMAGE_FETCH_TIMEOUT_MS);
      const generation = terminalImageGeneration;
      const promise = fetchTerminalImageBytes(
        base, sessionId, placement.imageId, placement.contentVersion, controller.signal
      ).then((result) => {
        if (terminalImageGeneration !== generation) return null;
        if (!makeRoomInTerminalImagePositiveCache(result.bytes.byteLength)) {
          blockTerminalImageOnCapacity(key);
          return null;
        }
        const url = URL.createObjectURL(new Blob([result.bytes], { type: 'image/png' }));
        const entry = {
          url,
          bytes: result.bytes.byteLength,
          width: result.width,
          height: result.height,
          activeNodeCount: 0,
          lastUsed: Date.now()
        };
        terminalImagePositiveCache.set(key, entry);
        terminalImageBackoff.delete(key);
        clearTimeout(terminalImageRetryTimers.get(key));
        terminalImageRetryTimers.delete(key);
        return entry;
      }).catch((error) => {
        if (terminalImageGeneration !== generation) return null;
        if (error?.code === 'not-found') {
          addTerminalImageNegativeCacheEntry(key);
        } else {
          const failureCount = (terminalImageBackoff.get(key)?.failureCount || 0) + 1;
          setTerminalImageBackoff(key, failureCount, generation);
        }
        return null;
      }).finally(() => {
        clearTimeout(timeoutId);
        if (terminalImageInFlight.get(key)?.promise === promise) {
          terminalImageInFlight.delete(key);
        }
        if (terminalImageGeneration === generation) {
          scheduleTerminalImageReconcile();
        }
      });
      terminalImageInFlight.set(key, { controller, promise });
      return promise;
    }

    // Invalidates a shared cache entry after a real browser decode failure
    // (structurally-valid-but-undecodable PNG bytes): revokes its one object
    // URL exactly once and clears it from every node currently displaying it,
    // so nothing visible is left pointing at a revoked URL.
    function invalidateTerminalImageCacheEntry(key) {
      const entry = terminalImagePositiveCache.get(key);
      if (entry) {
        URL.revokeObjectURL(entry.url);
        terminalImagePositiveCache.delete(key);
      }
      addBoundedTerminalImageKey(terminalImageDecodeFailures, key);
      terminalImageNodes.forEach((node) => {
        if (node.cacheKey !== key) return;
        terminalActiveDecodedPixels = Math.max(0, terminalActiveDecodedPixels - node.pixels);
        node.cacheKey = null;
        node.pixels = 0;
        node.el.removeAttribute('src');
      });
      // Conversation cards hold the *same* shared entry, so they must hand back
      // their pixels too — otherwise a decode failure leaves the budget charged
      // for images nothing displays until the owning card happens to change.
      clearConversationImageCacheKey(key);
      retryCapacityBlockedTerminalImages();
      // A different visible node may have been waiting only on the aggregate
      // decoded-pixel cap (not compressed-cache capacity). Invalidating this
      // image frees those pixels, so always reconcile even when the
      // capacity-blocked set is empty.
      scheduleTerminalImageReconcile();
    }

    function mountTerminalImageSource(node, cacheEntry, key) {
      node.cacheKey = key;
      node.pixels = cacheEntry.width * cacheEntry.height;
      cacheEntry.activeNodeCount += 1;
      cacheEntry.lastUsed = Date.now();
      terminalActiveDecodedPixels += node.pixels;
      node.el.onerror = () => invalidateTerminalImageCacheEntry(key);
      node.el.src = cacheEntry.url;
    }

    // Kicks off (or reuses) the bounded load for one placement. Safe to call
    // repeatedly (every reconciliation pass) for a node that isn't mounted
    // yet — `loadTerminalImage` itself is cheap once cached/negative/backed
    // off. The async continuation re-checks *current* state before touching
    // anything: a full session/generation change drops it outright, but an
    // unrelated text-only render in between must not — it reconciles against
    // whatever node/placement is current for this key at completion time.
    function attachTerminalImageSource(node, placement) {
      if (node.cacheKey || node.loadingKey || !selected) return;
      const sessionId = selected;
      const generation = terminalImageGeneration;
      const key = terminalImageCacheKey(
        sessionId, placement.imageId, placement.contentVersion
      );
      node.loadingKey = key;
      terminalImagePendingConsumers.set(
        key, (terminalImagePendingConsumers.get(key) || 0) + 1
      );
      loadTerminalImage(sessionId, placement).then((cacheEntry) => {
        if (terminalImageGeneration !== generation) return;
        const current = terminalImageNodes.get(placement.key);
        if (!current || current.el !== node.el || current.cacheKey
            || current.loadingKey !== key) return;
        if (!cacheEntry) return;
        if (terminalImagePositiveCache.get(key) !== cacheEntry) return;
        const pixels = cacheEntry.width * cacheEntry.height;
        if (terminalActiveDecodedPixels + pixels > TERMINAL_IMAGE_MAX_DECODED_PIXELS) return;
        mountTerminalImageSource(current, cacheEntry, key);
      }).finally(() => {
        const remaining = Math.max(
          0, (terminalImagePendingConsumers.get(key) || 1) - 1
        );
        if (remaining) terminalImagePendingConsumers.set(key, remaining);
        else terminalImagePendingConsumers.delete(key);
        if (node.loadingKey === key) node.loadingKey = null;
      });
    }

    function createTerminalImageNode(placement) {
      const el = document.createElement('img');
      el.className = 'terminal-image';
      el.alt = '';
      el.draggable = false;
      el.setAttribute('aria-hidden', 'true');
      terminalImageOverlay.append(el);
      const node = { el, cacheKey: null, loadingKey: null, pixels: 0 };
      attachTerminalImageSource(node, placement);
      return node;
    }

    function releaseTerminalImageNode(node) {
      node.el.remove();
      if (node.cacheKey) {
        const cacheEntry = terminalImagePositiveCache.get(node.cacheKey);
        if (cacheEntry) {
          cacheEntry.activeNodeCount = Math.max(0, cacheEntry.activeNodeCount - 1);
        }
        terminalActiveDecodedPixels = Math.max(0, terminalActiveDecodedPixels - node.pixels);
      }
      retryCapacityBlockedTerminalImages();
    }

    // --- Conversation-mode inline images -------------------------------------
    // Reuses the exact same bounded positive/negative/in-flight cache and byte
    // fetch as terminal images (deduping by sessionId:imageId:version), but with
    // its own node lifecycle because the transcript DOM is rebuilt each render.

    // Picks the JS-safe exact version string (UInt64 can exceed 2^53, so the
    // wire carries a decimal `contentVersionText`), mirroring terminal
    // placements. Returns null for anything unsafe so one bad ref can't break
    // the turn.
    function normalizeConversationImageRef(raw) {
      if (!raw || typeof raw !== 'object') return null;
      const { imageId, contentVersion, contentVersionText } = raw;
      if (!Number.isSafeInteger(imageId) || imageId < 1 || imageId > 0xFFFFFF) return null;
      const exactVersion = typeof contentVersionText === 'string'
        && /^[1-9][0-9]{0,19}$/.test(contentVersionText)
        ? contentVersionText
        : (Number.isSafeInteger(contentVersion) && contentVersion > 0
          ? String(contentVersion) : null);
      if (!exactVersion) return null;
      return { imageId, contentVersion: exactVersion };
    }

    // Mounts a decoded image into a conversation node, enforcing the same
    // shared decoded-pixel budget terminal mounts respect so conversation
    // images can never starve the terminal overlay. Returns whether it mounted;
    // a `false` (over budget) leaves the node blank to be retried on a later
    // render once budget frees.
    function mountConversationImage(node, cacheEntry, key) {
      const pixels = cacheEntry.width * cacheEntry.height;
      if (terminalActiveDecodedPixels + pixels > TERMINAL_IMAGE_MAX_DECODED_PIXELS) {
        return false;
      }
      node.cacheKey = key;
      node.pixels = pixels;
      cacheEntry.activeNodeCount += 1;
      cacheEntry.lastUsed = Date.now();
      terminalActiveDecodedPixels += pixels;
      node.el.onerror = () => invalidateTerminalImageCacheEntry(key);
      node.el.src = cacheEntry.url;
      // Lets the fullscreen viewer find (and pin) this decoded entry on click.
      node.el.dataset.cacheKey = key;
      return true;
    }

    function releaseConversationImageNode(node) {
      node.released = true;
      delete node.el.dataset.cacheKey;
      if (node.cacheKey) {
        const cacheEntry = terminalImagePositiveCache.get(node.cacheKey);
        if (cacheEntry) {
          cacheEntry.activeNodeCount = Math.max(0, cacheEntry.activeNodeCount - 1);
        }
        terminalActiveDecodedPixels = Math.max(0, terminalActiveDecodedPixels - node.pixels);
        node.cacheKey = null;
        node.pixels = 0;
      }
      retryCapacityBlockedTerminalImages();
    }

    // Builds one inline conversation image node. A cache hit mounts
    // synchronously (so an unchanged image keeps a non-zero reference across the
    // render swap); otherwise a bounded loader mounts it on completion. A
    // transient/capacity miss (null result or a full decoded-pixel budget) is
    // retried a few times with backoff so a temporary failure doesn't leave the
    // image permanently blank until the next unrelated transcript revision —
    // every attempt re-checks the node isn't released and the session/generation
    // hasn't moved on.
    function createConversationImageNode(sessionId, ref) {
      const figure = document.createElement('figure');
      figure.className = 'conversation-image';
      const el = document.createElement('img');
      el.className = 'conversation-image-img';
      el.alt = 'Terminal image';
      el.loading = 'lazy';
      el.draggable = false;
      figure.append(el);
      const node = { el, figure, cacheKey: null, pixels: 0, released: false };
      const key = terminalImageCacheKey(sessionId, ref.imageId, ref.contentVersion);
      const cached = terminalImagePositiveCache.get(key);
      if (cached) {
        cached.lastUsed = Date.now();
        if (mountConversationImage(node, cached, key)) return node;
      }
      const generation = terminalImageGeneration;
      const attempt = (remaining) => {
        if (node.released || node.cacheKey) return;
        if (terminalImageGeneration !== generation) return;
        loadTerminalImage(sessionId, ref).then((cacheEntry) => {
          if (node.released || node.cacheKey) return;
          if (terminalImageGeneration !== generation) return;
          if (cacheEntry
              && terminalImagePositiveCache.get(key) === cacheEntry
              && mountConversationImage(node, cacheEntry, key)) {
            return;
          }
          if (remaining > 0) {
            setTimeout(() => attempt(remaining - 1), CONVERSATION_IMAGE_RETRY_MS);
          }
        });
      };
      attempt(CONVERSATION_IMAGE_MAX_RETRIES);
      return node;
    }

    // --- Fullscreen image viewer (lightbox) --------------------------------
    // Clicking an inline conversation image opens it fullscreen with scroll/
    // pinch zoom and drag pan. While open, the decoded cache entry is pinned
    // (activeNodeCount bumped) so eviction can't revoke its blob URL underneath.
    const imageLightbox = document.querySelector('#image-lightbox');
    const imageLightboxImg = imageLightbox
      ? imageLightbox.querySelector('.image-lightbox-img') : null;
    const imageLightboxClose = imageLightbox
      ? imageLightbox.querySelector('.image-lightbox-close') : null;
    const LIGHTBOX_MIN_SCALE = 1;
    const LIGHTBOX_MAX_SCALE = 8;
    const lightboxState = {
      pinnedKey: null, scale: 1, tx: 0, ty: 0, moved: false,
      pointers: new Map(), pinch: null, pan: null, lastFocus: null,
    };

    function pinLightboxEntry(key) {
      if (!key) return;
      const entry = terminalImagePositiveCache.get(key);
      if (!entry) return;
      entry.activeNodeCount += 1;
      entry.lastUsed = Date.now();
      lightboxState.pinnedKey = key;
    }

    function unpinLightboxEntry() {
      const key = lightboxState.pinnedKey;
      lightboxState.pinnedKey = null;
      if (!key) return;
      const entry = terminalImagePositiveCache.get(key);
      if (entry) entry.activeNodeCount = Math.max(0, entry.activeNodeCount - 1);
      retryCapacityBlockedTerminalImages();
    }

    function applyLightboxTransform() {
      if (!imageLightboxImg) return;
      const zoomed = lightboxState.scale > 1.001;
      imageLightbox.classList.toggle('zoomed', zoomed);
      if (!zoomed) { lightboxState.tx = 0; lightboxState.ty = 0; }
      imageLightboxImg.style.transform =
        `translate(${lightboxState.tx}px, ${lightboxState.ty}px) scale(${lightboxState.scale})`;
    }

    function clampLightboxScale(s) {
      return Math.min(LIGHTBOX_MAX_SCALE, Math.max(LIGHTBOX_MIN_SCALE, s));
    }

    // Cursor/point relative to the image's untransformed top-left.
    function lightboxLocalPoint(clientX, clientY) {
      const r = imageLightboxImg.getBoundingClientRect();
      return { x: clientX - r.left + lightboxState.tx,
               y: clientY - r.top + lightboxState.ty };
    }

    // Zoom to nextScale while keeping content point under (qx,qy) fixed.
    function zoomLightboxAt(nextScale, qx, qy) {
      const s0 = lightboxState.scale;
      const s1 = clampLightboxScale(nextScale);
      if (s1 === s0) return;
      lightboxState.tx = qx - (s1 / s0) * (qx - lightboxState.tx);
      lightboxState.ty = qy - (s1 / s0) * (qy - lightboxState.ty);
      lightboxState.scale = s1;
      applyLightboxTransform();
    }

    function openImageLightbox(imgEl) {
      if (!imageLightbox || !imgEl) return;
      const src = imgEl.currentSrc || imgEl.src;
      if (!src) return;
      lightboxState.scale = 1; lightboxState.tx = 0; lightboxState.ty = 0;
      lightboxState.moved = false; lightboxState.pinch = null; lightboxState.pan = null;
      lightboxState.pointers.clear();
      pinLightboxEntry(imgEl.dataset ? imgEl.dataset.cacheKey : null);
      imageLightboxImg.src = src;
      imageLightbox.classList.add('open');
      imageLightbox.classList.remove('zoomed', 'panning');
      imageLightbox.setAttribute('aria-hidden', 'false');
      lightboxState.lastFocus = document.activeElement;
      applyLightboxTransform();
      if (imageLightboxClose) imageLightboxClose.focus();
    }

    function closeImageLightbox() {
      if (!imageLightbox || !imageLightbox.classList.contains('open')) return;
      imageLightbox.classList.remove('open', 'zoomed', 'panning');
      imageLightbox.setAttribute('aria-hidden', 'true');
      if (imageLightboxImg) imageLightboxImg.removeAttribute('src');
      lightboxState.pointers.clear();
      lightboxState.pinch = null; lightboxState.pan = null;
      unpinLightboxEntry();
      const prev = lightboxState.lastFocus;
      lightboxState.lastFocus = null;
      if (prev && typeof prev.focus === 'function') prev.focus();
    }

    function toggleLightboxZoom(evt) {
      if (lightboxState.moved) return;
      if (lightboxState.scale > 1.001) {
        lightboxState.scale = 1; lightboxState.tx = 0; lightboxState.ty = 0;
        applyLightboxTransform();
      } else {
        const q = lightboxLocalPoint(evt.clientX, evt.clientY);
        zoomLightboxAt(2.5, q.x, q.y);
      }
    }

    function lightboxPointerMid() {
      let sx = 0, sy = 0;
      lightboxState.pointers.forEach((p) => { sx += p.x; sy += p.y; });
      const n = lightboxState.pointers.size || 1;
      return { x: sx / n, y: sy / n };
    }

    function lightboxPointerDist() {
      const pts = [...lightboxState.pointers.values()];
      if (pts.length < 2) return 0;
      return Math.hypot(pts[0].x - pts[1].x, pts[0].y - pts[1].y);
    }

    if (imageLightbox && imageLightboxImg) {
      // Open from any inline conversation image click.
      transcript.addEventListener('click', (event) => {
        const target = event.target;
        if (target && target.classList
            && target.classList.contains('conversation-image-img')) {
          event.preventDefault();
          openImageLightbox(target);
        }
      });

      if (imageLightboxClose) {
        imageLightboxClose.addEventListener('click', closeImageLightbox);
      }
      // Click on the dark backdrop (but not the image/close) dismisses.
      imageLightbox.addEventListener('click', (event) => {
        if (event.target === imageLightbox) closeImageLightbox();
      });
      // Tap/click the image toggles fit <-> zoomed (unless it was a drag).
      imageLightboxImg.addEventListener('click', toggleLightboxZoom);

      imageLightbox.addEventListener('wheel', (event) => {
        event.preventDefault();
        const q = lightboxLocalPoint(event.clientX, event.clientY);
        const factor = event.deltaY < 0 ? 1.15 : 1 / 1.15;
        zoomLightboxAt(lightboxState.scale * factor, q.x, q.y);
      }, { passive: false });

      imageLightboxImg.addEventListener('pointerdown', (event) => {
        imageLightboxImg.setPointerCapture(event.pointerId);
        lightboxState.pointers.set(event.pointerId,
          { x: event.clientX, y: event.clientY });
        lightboxState.moved = false;
        if (lightboxState.pointers.size === 2) {
          lightboxState.pan = null;
          lightboxState.pinch = { dist: lightboxPointerDist(), scale: lightboxState.scale };
        } else if (lightboxState.pointers.size === 1) {
          lightboxState.pan = { tx: lightboxState.tx, ty: lightboxState.ty,
            x: event.clientX, y: event.clientY };
        }
      });

      imageLightboxImg.addEventListener('pointermove', (event) => {
        const p = lightboxState.pointers.get(event.pointerId);
        if (!p) return;
        p.x = event.clientX; p.y = event.clientY;
        if (lightboxState.pointers.size >= 2 && lightboxState.pinch) {
          const dist = lightboxPointerDist();
          if (lightboxState.pinch.dist > 0 && dist > 0) {
            const mid = lightboxPointerMid();
            const q = lightboxLocalPoint(mid.x, mid.y);
            zoomLightboxAt(lightboxState.pinch.scale * (dist / lightboxState.pinch.dist),
              q.x, q.y);
          }
          lightboxState.moved = true;
        } else if (lightboxState.pan && lightboxState.scale > 1.001) {
          const dx = event.clientX - lightboxState.pan.x;
          const dy = event.clientY - lightboxState.pan.y;
          if (Math.abs(dx) > 3 || Math.abs(dy) > 3) {
            lightboxState.moved = true;
            imageLightbox.classList.add('panning');
          }
          lightboxState.tx = lightboxState.pan.tx + dx;
          lightboxState.ty = lightboxState.pan.ty + dy;
          applyLightboxTransform();
        }
      });

      const endPointer = (event) => {
        lightboxState.pointers.delete(event.pointerId);
        if (lightboxState.pointers.size < 2) lightboxState.pinch = null;
        if (lightboxState.pointers.size === 0) {
          lightboxState.pan = null;
          imageLightbox.classList.remove('panning');
        }
      };
      imageLightboxImg.addEventListener('pointerup', endPointer);
      imageLightboxImg.addEventListener('pointercancel', endPointer);

      document.addEventListener('keydown', (event) => {
        if (event.key === 'Escape' && imageLightbox.classList.contains('open')) {
          event.preventDefault();
          closeImageLightbox();
        }
      });
    }

    function terminalImageViewportRange() {
      const lineHeight = measuredLineHeight();
      const start = historyStartLine + Math.floor(terminal.scrollTop / lineHeight);
      const end = start + Math.ceil(terminal.clientHeight / lineHeight) + 1;
      return { start, end };
    }

    function visibleTerminalImagePlacements() {
      const { start, end } = terminalImageViewportRange();
      const cellWidth = measuredCellWidth();
      const firstColumn = Math.max(0, Math.floor(terminal.scrollLeft / cellWidth));
      const lastColumn = firstColumn + Math.ceil(terminal.clientWidth / cellWidth) + 1;
      return imagePlacements
        .filter((placement) => placement.absoluteLine < end
          && placement.absoluteLine + placement.rows > start
          && placement.column < lastColumn
          && placement.column + placement.columns > firstColumn)
        .slice(0, TERMINAL_IMAGE_MAX_RENDERED_NODES);
    }

    // Renders/reconciles at most `TERMINAL_IMAGE_MAX_RENDERED_NODES` actual
    // DOM nodes based on the current viewport: nodes for placements that
    // fell out of view are removed, nodes for still-visible placements are
    // repositioned in place (never recreated) by their stable key, and newly
    // visible placements get a fresh node.
    function reconcileTerminalImageOverlay() {
      const visible = visibleTerminalImagePlacements();
      const nextKeys = new Set(visible.map((placement) => placement.key));
      [...terminalImageNodes.entries()].forEach(([key, node]) => {
        if (!nextKeys.has(key)) {
          releaseTerminalImageNode(node);
          terminalImageNodes.delete(key);
        }
      });
      const cellWidth = measuredCellWidth();
      const lineHeight = measuredLineHeight();
      visible.forEach((placement) => {
        let node = terminalImageNodes.get(placement.key);
        if (!node) {
          node = createTerminalImageNode(placement);
          terminalImageNodes.set(placement.key, node);
        } else {
          attachTerminalImageSource(node, placement);
        }
        node.el.style.top = `${(placement.absoluteLine - historyStartLine) * lineHeight}px`;
        node.el.style.left = `${placement.column * cellWidth}px`;
        node.el.style.width = `${placement.columns * cellWidth}px`;
        node.el.style.height = `${placement.rows * lineHeight}px`;
      });
    }

    function scheduleTerminalImageReconcile() {
      if (terminalImageReconcileScheduled) return;
      terminalImageReconcileScheduled = true;
      requestAnimationFrame(() => {
        terminalImageReconcileScheduled = false;
        reconcileTerminalImageOverlay();
      });
    }

    // Clears placement state and every currently-mounted overlay node, but
    // leaves the positive/negative/backoff caches alone — a session switch
    // may switch right back, and cached bytes/outcomes for a still-live
    // session remain valid.
    function clearTerminalImageDisplayState() {
      [...terminalImageNodes.values()].forEach(releaseTerminalImageNode);
      terminalImageNodes.clear();
      clearTranscriptDOM();
      imagePlacements = [];
      terminalActiveDecodedPixels = 0;
      terminalImageOverlay.replaceChildren();
    }

    // Session change / terminal refresh: bump the generation so any
    // completion still in flight for the *previous* session can never
    // repopulate cleared state, then abort every in-flight request — none of
    // them can possibly belong to the session we're switching to, since it
    // hasn't requested anything yet.
    function resetTerminalImagesForSessionChange() {
      closeImageLightbox();
      terminalImageGeneration += 1;
      terminalImageInFlight.forEach((request) => request.controller.abort());
      terminalImageInFlight.clear();
      terminalImagePendingConsumers.clear();
      clearTerminalImageDisplayState();
    }

    // Full auth reset / sign-out: additionally revoke every retained object
    // URL and wipe every cache, so nothing survives into whatever session
    // reconnects next.
    function resetTerminalImagesForSignOut() {
      resetTerminalImagesForSessionChange();
      terminalImagePositiveCache.forEach((entry) => URL.revokeObjectURL(entry.url));
      terminalImagePositiveCache.clear();
      terminalImageNegativeCache.clear();
      terminalImageDecodeFailures.clear();
      terminalImageCapacityBlocked.clear();
      terminalImageBackoff.clear();
      terminalImageRetryTimers.forEach(clearTimeout);
      terminalImageRetryTimers.clear();
    }

    function renderLines(screen) {
      const wasAtBottom =
        terminal.scrollHeight - terminal.scrollTop - terminal.clientHeight < 12;
      const previousTop = historyStartLine + Math.floor(
        terminal.scrollTop / measuredLineHeight()
      );

      if (screen.scrollMode === 'terminal' || screen.reset || !lastScreen
          || lastScreen.scrollMode !== screen.scrollMode) {
        historyStartLine = screen.firstLine;
        historyLines = [...screen.lines];
      } else {
        const trim = Math.max(0, screen.historyStartLine - historyStartLine);
        if (trim) {
          historyLines.splice(0, trim);
          historyStartLine += trim;
        }
        const offset = screen.firstLine - historyStartLine;
        if (offset < 0 || offset > historyLines.length) {
          historyStartLine = screen.firstLine;
          historyLines = [...screen.lines];
        } else {
          historyLines.splice(offset, screen.lines.length, ...screen.lines);
        }
      }
      while (historyLines.length
          && historyStartLine + historyLines.length > screen.liveTopLine + screen.rows) {
        historyLines.pop();
      }

      // Authoritative on any modern host (a present `images` array, `[]`
      // included) fully replaces placement state every screen event, live or
      // incremental history alike; only an old host that omits the field
      // entirely (`images == null`) leaves prior placement state untouched.
      if (Array.isArray(screen.images)) {
        imagePlacements = buildTerminalImagePlacements(screen);
      }
      // Whichever branch above ran, bound placement state to the line range
      // this client actually still retains — including the reset branch a
      // few lines up, where `historyStartLine`/`historyLines` were just
      // replaced wholesale.
      const retainedStart = historyStartLine;
      const retainedEnd = historyStartLine + historyLines.length;
      imagePlacements = imagePlacements.filter((placement) => (
        placement.absoluteLine < retainedEnd
        && placement.absoluteLine + placement.rows > retainedStart
      ));

      const fragment = document.createDocumentFragment();
      historyLines.forEach((line) => {
        const row = document.createElement('div');
        row.className = 'terminal-line';
        appendLinkedText(row, line);
        fragment.append(row);
      });
      terminalLines.replaceChildren(fragment);
      terminal.classList.toggle('terminal-scroll', screen.scrollMode === 'terminal');

      const lineHeight = measuredLineHeight();
      const saved = selected && sessionScroll.get(selected);
      if (screen.scrollMode === 'terminal' || wasAtBottom || saved?.atBottom) {
        terminal.scrollTop = terminal.scrollHeight;
      } else {
        const topLine = saved?.topLine ?? previousTop;
        terminal.scrollTop = Math.max(0, topLine - historyStartLine) * lineHeight;
      }
      lastScreen = screen;
      scheduleTerminalImageReconcile();
    }

    const sessionScroll = new Map();
    terminal.addEventListener('scroll', () => {
      scheduleTerminalImageReconcile();
      if (!selected || lastScreen?.scrollMode !== 'history') return;
      const lineHeight = measuredLineHeight();
      const atBottom =
        terminal.scrollHeight - terminal.scrollTop - terminal.clientHeight < 12;
      sessionScroll.set(selected, {
        atBottom,
        topLine: historyStartLine + Math.floor(terminal.scrollTop / lineHeight)
      });
    });
    window.addEventListener('resize', () => scheduleTerminalImageReconcile());

    function requestTerminalScroll(delta) {
      if (!selected || !writable || lastScreen?.scrollMode !== 'terminal') return;
      pendingScroll += delta;
      clearTimeout(scrollTimer);
      scrollTimer = setTimeout(() => {
        const value = Math.sign(pendingScroll)
          * Math.min(Math.abs(pendingScroll), 8);
        pendingScroll = 0;
        if (value) control({
          type: 'scroll',
          sessionId: selected,
          delta: value
        }).then((response) => {
          if (response?.status === 403) {
            writable = false;
            lease.textContent = 'view only';
            updatePromptState();
          }
        });
      }, 16);
    }

    terminal.addEventListener('wheel', (event) => {
      if (lastScreen?.scrollMode !== 'terminal') return;
      event.preventDefault();
      // Wire convention: positive means up/toward older content.
      requestTerminalScroll(event.deltaY > 0 ? -3 : 3);
    }, {passive:false});

    terminal.addEventListener('touchstart', (event) => {
      if (lastScreen?.scrollMode === 'terminal') {
        touchY = event.touches[0]?.clientY ?? null;
      }
    }, {passive:true});
    terminal.addEventListener('touchmove', (event) => {
      if (lastScreen?.scrollMode !== 'terminal' || touchY == null) return;
      event.preventDefault();
      const next = event.touches[0]?.clientY ?? touchY;
      const delta = next - touchY;
      if (Math.abs(delta) >= 18) {
        requestTerminalScroll(delta > 0 ? 2 : -2);
        touchY = next;
      }
    }, {passive:false});
    terminal.addEventListener('touchend', () => { touchY = null; });

    function onMessage(event) {
      const message = JSON.parse(event.data);
      if (message.type === 'workspace') renderWorkspace(message.data);
      if (message.type === 'screen' && message.data.sessionId === selected) {
        if (viewMode === 'terminal') renderLines(message.data);
      }
      if (message.type === 'dismissed-notifications') {
        clearDismissedNotifications(message.data.ids || []);
      }
      if (message.type === 'transcript' && message.data.sessionId === selected) {
        if (awaitingPromptStart) {
          awaitingPromptStart = false;
          clearTimeout(promptFallbackTimer);
          promptFallbackTimer = null;
          updatePromptState();
        }
        fetchTranscript(message.data);
      }
    }

    async function clearDismissedNotifications(ids) {
      if (!('serviceWorker' in navigator) || !ids.length) return;
      const registration = await navigator.serviceWorker.ready;
      const dismissed = new Set(ids);
      const notifications = await registration.getNotifications();
      notifications.forEach((notification) => {
        if (dismissed.has(notification.tag)) notification.close();
      });
    }
    terminal.addEventListener('keydown', (event) => {
      if (!writable) return;
      const specialKey = {
        Enter:'enter', Backspace:'backspace', Tab:'tab', Escape:'escape',
        ArrowUp:'up', ArrowDown:'down', ArrowRight:'right', ArrowLeft:'left'
      };
      const key = specialKey[event.key];
      if (key) {
        event.preventDefault();
        sendKey(key);
        return;
      }
      let data = null;
      if (!data && event.ctrlKey && event.key.length === 1) {
        data = String.fromCharCode(event.key.toUpperCase().charCodeAt(0) - 64);
      } else if (!data && event.key.length === 1 && !event.metaKey) {
        data = event.key;
      }
      if (data) { event.preventDefault(); sendInput(data); }
    });
    document.querySelectorAll('#toolbar button').forEach((button) => {
      button.onclick = () => {
        if (button.dataset.key === 'ctrl-c') sendInput('\u0003');
        else sendKey(TOOLBAR_KEYS[button.dataset.key]);
      };
    });
    pivotTabs.forEach((tab) => {
      tab.onclick = () => setViewMode(tab.dataset.mode);
    });
    document.querySelector('#pivot-tabs').addEventListener('keydown', (event) => {
      if (event.key !== 'ArrowLeft' && event.key !== 'ArrowRight') return;
      event.preventDefault();
      const current = pivotTabs.findIndex(
        (tab) => tab.dataset.mode === viewMode
      );
      const step = event.key === 'ArrowRight' ? 1 : -1;
      const next = pivotTabs[(current + step + pivotTabs.length) % pivotTabs.length];
      if (next) { setViewMode(next.dataset.mode, {silent:true}); next.focus(); }
    });
    newSessionButton.onclick = () => { createSession(); };
    closeSessionButton.onclick = () => { closeCurrentSession(); };
    newSessionProject.onchange = () => {
      const nextProjectId = newSessionProject.value || null;
      if (createTargetProjectId === nextProjectId) return;
      createTargetProjectId = nextProjectId;
      if (createRequestProjectId !== createTargetProjectId) {
        clearCreateRequest();
      }
      setCreateStatus('');
      updateNewSessionState();
    };
    updateNewSessionState();
    document.querySelector('#input-form').onsubmit = (event) => {
      event.preventDefault();
      if (input.value) {
        sendInput(input.value);
        sendKey('enter');
      }
      input.value = '';
      terminal.focus();
    };
    // Enter sends the prompt; Shift+Enter inserts a newline (chat-composer style).
    prompt.addEventListener('keydown', (event) => {
      if (event.key === 'Enter' && !event.shiftKey && !event.isComposing) {
        event.preventDefault();
        promptForm.requestSubmit();
      }
    });
    prompt.addEventListener('input', () => {
      // Mirror the selectSession() guard: don't resurrect a draft for a
      // session that was just pruned from the workspace snapshot while its
      // composer is still visible and the user keeps typing into it.
      if (selected && sessionState.has(selected)) {
        setPromptDraft(selected, prompt.value);
      }
      updatePromptState();
    });
    promptForm.onsubmit = (event) => {
      event.preventDefault();
      if (enqueuePrompt(prompt.value)) {
        prompt.value = '';
        setPromptDraft(selected, '');
        persistPromptDrafts();
        updatePromptState();
      }
    };
    window.addEventListener('pagehide', persistPromptDrafts);
    document.addEventListener('visibilitychange', () => {
      if (document.visibilityState === 'hidden') persistPromptDrafts();
    });

    function base64URLToBytes(value) {
      const padded = value.replace(/-/g, '+').replace(/_/g, '/')
        + '='.repeat((4 - value.length % 4) % 4);
      const raw = atob(padded);
      return Uint8Array.from(raw, (character) => character.charCodeAt(0));
    }

    function bytesToBase64URL(value) {
      const bytes = new Uint8Array(value);
      let raw = '';
      bytes.forEach((byte) => { raw += String.fromCharCode(byte); });
      return btoa(raw).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
    }

    async function registerSubscription(subscription, publicKey) {
      const response = await fetch(`${base}push/subscribe`, {
        method: 'POST',
        headers: {'Content-Type':'application/json'},
        body: JSON.stringify({
          subscription: {
            ...subscription.toJSON(),
            applicationServerKey: publicKey
          },
          label: navigator.userAgent.slice(0, 120),
          capabilities: ['clear-action']
        })
      });
      if (!response.ok) throw new Error(`Subscription failed (${response.status})`);
      notifications.className = 'enabled';
      notifications.title = 'Web notifications enabled';
      notifications.setAttribute('aria-label', 'Web notifications enabled');
    }

    async function setupNotifications(requestPermission) {
      const isIOS = /iPad|iPhone|iPod/.test(navigator.userAgent);
      const standalone = matchMedia('(display-mode: standalone)').matches
        || navigator.standalone === true;
      if (!('serviceWorker' in navigator) || !('PushManager' in window)
          || !('Notification' in window)) {
        notifications.className = 'unsupported';
        notifications.title = 'Web notifications are not supported';
        return;
      }
      if (isIOS && !standalone) {
        notifications.className = 'unsupported';
        notifications.title = 'Add this app to the Home Screen to enable notifications';
        return;
      }
      const registration = await navigator.serviceWorker.register(`${base}sw.js`);
      let subscription = await registration.pushManager.getSubscription();
      const keyResponse = await fetch(`${base}push/public-key`);
      if (!keyResponse.ok) throw new Error('Push service unavailable');
      const {applicationServerKey} = await keyResponse.json();

      if (subscription?.options?.applicationServerKey
          && bytesToBase64URL(subscription.options.applicationServerKey)
            !== applicationServerKey) {
        await subscription.unsubscribe();
        subscription = null;
      }
      if (!subscription && requestPermission) {
        const permission = await Notification.requestPermission();
        if (permission !== 'granted') {
          notifications.className = 'denied';
          notifications.title = 'Web notification permission denied';
          return;
        }
        subscription = await registration.pushManager.subscribe({
          userVisibleOnly: true,
          applicationServerKey: base64URLToBytes(applicationServerKey)
        });
      }
      if (subscription) {
        await registerSubscription(subscription, applicationServerKey);
      }
    }

    notifications.onclick = async () => {
      try {
        await setupNotifications(true);
      } catch (error) {
        notifications.className = 'denied';
        notifications.title = `Web notifications failed: ${error.message}`;
      }
    };
    setupNotifications(false).catch(() => {});

    navigator.serviceWorker?.addEventListener('message', (event) => {
      if (event.data?.type !== 'focus-session') return;
      pendingFocusSession = event.data.sessionId || null;
      if (pendingFocusSession) {
        const target = document.querySelector(
          `nav button[data-id="${CSS.escape(pendingFocusSession)}"]`
        );
        if (target) {
          const sessionId = pendingFocusSession;
          pendingFocusSession = null;
          selectSession(sessionId);
        }
      }
    });

    openStream();
    """#
}
