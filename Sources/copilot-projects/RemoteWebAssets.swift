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
              <div id="prompt-warning">Sending clears any unsent desktop draft.</div>
              <button id="prompt-submit" disabled>Send message</button>
            </form>
          </aside>
          <section id="terminal-pane" role="tabpanel" aria-label="Terminal">
            <div id="toolbar">
              <button data-key="esc">Esc</button>
              <button data-key="ctrl-c">Ctrl-C</button>
              <button data-key="tab">Tab</button>
              <button data-key="up">↑</button>
              <button data-key="down">↓</button>
              <span id="lease">view only</span>
            </div>
            <div id="terminal" role="region" aria-live="off"
              aria-label="Terminal output" tabindex="0">Select a session</div>
            <form id="input-form">
              <input id="input" autocomplete="off" autocapitalize="none" spellcheck="false"
                aria-label="Command input" placeholder="Send a command">
              <button>Send</button>
            </form>
          </section>
        </div>
      </main>
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
    header { flex: 0 0 48px; display:flex; align-items:center; justify-content:space-between;
      padding: 0 14px; border-bottom: 1px solid #333; }
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
    #terminal { flex:1; min-height:0; overflow:auto; -webkit-overflow-scrolling:touch;
      overscroll-behavior:contain; margin:0; padding:10px; outline:none;
      font: 13px/1.25 ui-monospace, SFMono-Regular, Menlo, monospace; white-space:pre;
      touch-action:pan-y; }
    #terminal.terminal-scroll { touch-action:none; }
    .terminal-line { min-height:1.25em; }
    .terminal-link { color:#58a6ff; text-decoration:underline; text-underline-offset:2px; }
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
    .turn { margin:0 0 12px; padding:10px; border:1px solid #333; border-radius:10px;
      background:#1d1d1d; }
    .turn-header { display:flex; justify-content:space-between; gap:8px;
      color:#999; font-size:11px; margin-bottom:8px; }
    .stopped { color:#d29922; }
    .message { white-space:pre-wrap; overflow-wrap:anywhere; margin:6px 0;
      padding:8px; border-radius:7px; background:#252525; }
    .message.user { background:#1d3150; }
    .message-label { display:block; color:#999; font-size:10px; font-weight:600;
      margin-bottom:4px; text-transform:uppercase; }
    .tools { color:#aaa; font-size:11px; margin-top:7px; }
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
    @media (max-width: 700px) {
      main { grid-template-columns: 92px minmax(0, 1fr); }
      nav { padding:4px; }
      nav button { padding:7px 5px; font-size:12px; }
      #terminal { font-size:10px; padding:6px; }
      #toolbar button { padding:6px 8px; }
      #toolbar { flex-wrap:wrap; height:auto; }
      .pivot-tab { padding:6px 11px; }
    }
    """#

    static let javascript = #"""
    const sessions = document.querySelector('#sessions');
    const terminal = document.querySelector('#terminal');
    const connection = document.querySelector('#connection');
    const lease = document.querySelector('#lease');
    const input = document.querySelector('#input');
    const transcript = document.querySelector('#transcript');
    const promptForm = document.querySelector('#prompt-form');
    const prompt = document.querySelector('#prompt');
    const promptStatus = document.querySelector('#prompt-status');
    const promptSubmit = document.querySelector('#prompt-submit');
    const userInput = document.querySelector('#user-input');
    const promptQueue = document.querySelector('#prompt-queue');
    const notifications = document.querySelector('#notifications');
    const content = document.querySelector('#content');
    const pivotTabs = Array.from(document.querySelectorAll('.pivot-tab'));
    const base = location.pathname.endsWith('/')
      ? location.pathname : `${location.pathname}/`;
    const clientId = (crypto.randomUUID && crypto.randomUUID()) ||
      `c-${Date.now()}-${Math.random().toString(16).slice(2)}`;
    const TOOLBAR_KEYS = {
      'esc': 'escape', 'tab': 'tab', 'up': 'up', 'down': 'down'
    };
    let stream = null;
    let selected = null;
    let writable = false;
    let pendingActions = [];
    let flushing = false;
    let lastScreen = null;
    let historyStartLine = 0;
    let historyLines = [];
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
    const sessionState = new Map();
    // requestId -> card element, and requestId -> { timer, token } while an answer
    // is awaiting confirmation from the workspace snapshot.
    const userInputCards = new Map();
    const submittingUserInputs = new Map();
    const latestUserInputAttempts = new Map();
    let userInputAttemptSequence = 0;
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
      terminal.textContent = selected ? 'Loading…' : 'Select a session';
      if (selected) openStream();
    }
    function setViewMode(mode, options) {
      if (mode !== 'terminal' && mode !== 'conversation') return;
      const changed = viewMode !== mode;
      viewMode = mode;
      content.dataset.mode = mode;
      pivotTabs.forEach((tab) => {
        tab.setAttribute('aria-selected', String(tab.dataset.mode === mode));
      });
      if (mode === 'terminal') {
        if (changed) refreshTerminal();
        if (!options?.silent) terminal.focus();
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
    async function acquire(id) {
      const response = await control({ type: 'acquire', sessionId: id });
      if (selected !== id) return;
      if (response && response.ok) {
        writable = true;
        lease.textContent = 'control enabled';
        syncUserInputCards();
        updatePromptState();
      }
    }
    function selectSession(id) {
      selected = id;
      writable = false;
      pendingActions.length = 0;
      pendingScroll = 0;
      lastScreen = null;
      historyStartLine = 0;
      historyLines = [];
      promptSending = false;
      awaitingPromptStart = false;
      transcriptRequestId += 1;
      selectionGeneration += 1;
      clearTimeout(promptFallbackTimer);
      promptFallbackTimer = null;
      clearTimeout(scrollTimer);
      scrollTimer = null;
      resetUserInputCards();
      lease.textContent = 'view only';
      terminal.textContent = 'Loading…';
      transcript.innerHTML = '<div class="transcript-empty">Loading completed turns…</div>';
      terminal.classList.remove('terminal-scroll');
      document.querySelectorAll('nav button').forEach((button) => {
        button.classList.toggle('active', button.dataset.id === id);
      });
      openStream();
      acquire(id);
      if (viewMode === 'terminal') terminal.focus();
      syncUserInputCards();
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
    function updatePromptState(message) {
      const state = selected && sessionState.get(selected);
      const pendingInputs = (state && state.pendingUserInputs) || [];
      const hasQuestions = pendingInputs.length > 0;
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
      question.textContent = request.question;
      card.append(question);
      const choices = Array.isArray(request.choices) ? request.choices : [];
      if (choices.length) {
        const group = document.createElement('div');
        group.className = 'user-input-choices';
        choices.forEach((choice) => {
          const button = document.createElement('button');
          button.type = 'button';
          button.className = 'user-input-choice';
          button.textContent = choice;
          button.onclick = () => submitUserInput(request.requestId, choice, false);
          group.append(button);
        });
        card.append(group);
      }
      if (request.allowFreeform) {
        const freeform = document.createElement('form');
        freeform.className = 'user-input-freeform';
        const field = document.createElement('textarea');
        field.rows = 2;
        field.maxLength = 8192;
        field.setAttribute('aria-label', 'Type an answer');
        field.placeholder = 'Type an answer';
        const submit = document.createElement('button');
        submit.type = 'submit';
        submit.textContent = 'Send answer';
        freeform.append(field, submit);
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

    function transcriptMessage(label, text, className) {
      const container = document.createElement('div');
      container.className = `message ${className}`;
      const heading = document.createElement('span');
      heading.className = 'message-label';
      heading.textContent = label;
      container.append(heading);
      appendLinkedText(container, text);
      return container;
    }

    function renderTranscript(snapshot) {
      const wasAtBottom =
        transcript.scrollHeight - transcript.scrollTop - transcript.clientHeight < 18;
      const fragment = document.createDocumentFragment();
      const turns = snapshot?.turns || [];
      if (!turns.length) {
        const empty = document.createElement('div');
        empty.className = 'transcript-empty';
        empty.textContent = 'Completed turns will appear here.';
        fragment.append(empty);
      }
      turns.forEach((turn) => {
        const card = document.createElement('article');
        card.className = 'turn';
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
        fragment.append(card);
      });
      transcript.replaceChildren(fragment);
      if (wasAtBottom) transcript.scrollTop = transcript.scrollHeight;
    }

    async function fetchTranscript(revision) {
      const sessionId = revision.sessionId;
      const requestId = ++transcriptRequestId;
      try {
        const response = await fetch(
          `${base}transcript?s=${encodeURIComponent(sessionId)}`,
          { cache: 'no-store' }
        );
        if (!response.ok || selected !== sessionId
            || requestId !== transcriptRequestId) return;
        const snapshot = await response.json();
        if (selected === sessionId && requestId === transcriptRequestId) {
          renderTranscript(snapshot);
        }
      } catch {
        if (selected === sessionId && requestId === transcriptRequestId) {
          const empty = document.createElement('div');
          empty.className = 'transcript-empty';
          empty.textContent = 'Could not load completed turns.';
          transcript.replaceChildren(empty);
        }
      }
    }

    function renderLines(screen) {
      const wasAtBottom =
        terminal.scrollHeight - terminal.scrollTop - terminal.clientHeight < 12;
      const previousTop = historyStartLine + Math.floor(
        terminal.scrollTop / Math.max(
          terminal.querySelector('.terminal-line')?.getBoundingClientRect().height || 16,
          1
        )
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

      const fragment = document.createDocumentFragment();
      historyLines.forEach((line) => {
        const row = document.createElement('div');
        row.className = 'terminal-line';
        appendLinkedText(row, line);
        fragment.append(row);
      });
      terminal.replaceChildren(fragment);
      terminal.classList.toggle('terminal-scroll', screen.scrollMode === 'terminal');

      const lineHeight = Math.max(
        terminal.querySelector('.terminal-line')?.getBoundingClientRect().height || 16,
        1
      );
      const saved = selected && sessionScroll.get(selected);
      if (screen.scrollMode === 'terminal' || wasAtBottom || saved?.atBottom) {
        terminal.scrollTop = terminal.scrollHeight;
      } else {
        const topLine = saved?.topLine ?? previousTop;
        terminal.scrollTop = Math.max(0, topLine - historyStartLine) * lineHeight;
      }
      lastScreen = screen;
    }

    const sessionScroll = new Map();
    terminal.addEventListener('scroll', () => {
      if (!selected || lastScreen?.scrollMode !== 'history') return;
      const lineHeight = Math.max(
        terminal.querySelector('.terminal-line')?.getBoundingClientRect().height || 16,
        1
      );
      const atBottom =
        terminal.scrollHeight - terminal.scrollTop - terminal.clientHeight < 12;
      sessionScroll.set(selected, {
        atBottom,
        topLine: historyStartLine + Math.floor(terminal.scrollTop / lineHeight)
      });
    });

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
    prompt.addEventListener('input', () => updatePromptState());
    promptForm.onsubmit = (event) => {
      event.preventDefault();
      if (enqueuePrompt(prompt.value)) {
        prompt.value = '';
        updatePromptState();
      }
    };

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
