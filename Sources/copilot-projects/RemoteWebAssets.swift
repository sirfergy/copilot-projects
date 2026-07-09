import Foundation

enum RemoteWebAssets {
    static let html = #"""
    <!doctype html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
      <meta name="referrer" content="no-referrer">
      <title>Copilot Projects</title>
      <link rel="stylesheet" href="app.css">
    </head>
    <body>
      <header><strong>Copilot Projects</strong><span id="connection">connecting</span></header>
      <main>
        <nav id="sessions"></nav>
        <section>
          <div id="toolbar">
            <button data-key="esc">Esc</button>
            <button data-key="ctrl-c">Ctrl-C</button>
            <button data-key="tab">Tab</button>
            <button data-key="up">↑</button>
            <button data-key="down">↓</button>
            <span id="lease">view only</span>
          </div>
          <pre id="terminal" tabindex="0">Select a session</pre>
          <form id="input-form">
            <input id="input" autocomplete="off" autocapitalize="none" spellcheck="false"
              placeholder="Send a command">
            <button>Send</button>
          </form>
        </section>
      </main>
      <script src="app.js"></script>
    </body>
    </html>
    """#

    static let css = #"""
    :root { color-scheme: dark; font-family: -apple-system, BlinkMacSystemFont, sans-serif; }
    * { box-sizing: border-box; }
    html, body { margin: 0; background: #111; color: #eee; }
    body { height: 100vh; height: 100dvh; overflow: hidden;
      display: flex; flex-direction: column; }
    header { flex: 0 0 48px; display:flex; align-items:center; justify-content:space-between;
      padding: 0 14px; border-bottom: 1px solid #333; }
    #connection { color:#999; font-size:12px; }
    main { flex:1; min-height:0; display:grid;
      grid-template-columns: minmax(180px, 260px) 1fr; }
    nav { overflow:auto; -webkit-overflow-scrolling:touch; overscroll-behavior:contain;
      border-right:1px solid #333; padding:8px; }
    nav h3 { color:#999; font-size:12px; margin:12px 6px 5px; }
    nav button { display:block; width:100%; text-align:left; margin:2px 0; padding:9px;
      border:0; border-radius:7px; background:transparent; color:#ddd; }
    nav button.active { background:#29334a; }
    nav small { display:block; color:#999; margin-top:3px; }
    section { min-width:0; min-height:0; display:flex; flex-direction:column; }
    #toolbar { flex:0 0 auto; display:flex; align-items:center; gap:6px; padding:5px 8px;
      border-bottom:1px solid #333; }
    button { background:#2c2c2c; color:#eee; border:1px solid #444; border-radius:6px;
      padding:7px 10px; }
    #lease { margin-left:auto; color:#999; font-size:12px; }
    #terminal { flex:1; min-height:0; overflow:auto; -webkit-overflow-scrolling:touch;
      overscroll-behavior:contain; margin:0; padding:10px; outline:none;
      font: 13px/1.25 ui-monospace, SFMono-Regular, Menlo, monospace; white-space:pre; }
    #input-form { flex:0 0 auto; display:flex; gap:8px; padding:8px; border-top:1px solid #333;
      padding-bottom:max(8px, env(safe-area-inset-bottom)); }
    #input { flex:1; min-width:0; background:#222; color:#fff; border:1px solid #555;
      border-radius:7px; padding:10px; font-size:16px; }
    @media (max-width: 700px) {
      main { grid-template-columns: 118px 1fr; }
      nav { padding:4px; }
      nav button { padding:7px 5px; font-size:12px; }
      #terminal { font-size:10px; padding:6px; }
      #toolbar button { padding:6px 8px; }
      #toolbar { flex-wrap:wrap; height:auto; }
    }
    """#

    static let javascript = #"""
    const sessions = document.querySelector('#sessions');
    const terminal = document.querySelector('#terminal');
    const connection = document.querySelector('#connection');
    const lease = document.querySelector('#lease');
    const input = document.querySelector('#input');
    const base = location.pathname.endsWith('/')
      ? location.pathname : `${location.pathname}/`;
    const clientId = (crypto.randomUUID && crypto.randomUUID()) ||
      `c-${Date.now()}-${Math.random().toString(16).slice(2)}`;
    const TOOLBAR_KEYS = {
      'esc': '\u001b', 'ctrl-c': '\u0003', 'tab': '\t',
      'up': '\u001b[A', 'down': '\u001b[B'
    };
    let stream = null;
    let selected = null;
    let writable = false;
    let pendingInput = '';
    let flushing = false;

    function openStream() {
      if (stream) stream.close();
      const query = new URLSearchParams();
      if (selected) query.set('s', selected);
      const suffix = query.toString() ? `?${query.toString()}` : '';
      stream = new EventSource(`${base}events${suffix}`);
      stream.onopen = () => { connection.textContent = 'connected'; };
      stream.onerror = () => { connection.textContent = 'reconnecting'; };
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
        connection.textContent = 'error';
        return null;
      }
    }
    async function acquire(id) {
      const response = await control({ type: 'acquire', sessionId: id });
      if (selected !== id) return;
      if (response && response.ok) {
        writable = true;
        lease.textContent = 'control enabled';
      }
    }
    function selectSession(id) {
      selected = id;
      writable = false;
      pendingInput = '';
      lease.textContent = 'view only';
      terminal.textContent = 'Loading…';
      document.querySelectorAll('nav button').forEach((button) => {
        button.classList.toggle('active', button.dataset.id === id);
      });
      openStream();
      acquire(id);
      terminal.focus();
    }
    // Buffer keystrokes and send them in order, one request in flight at a time,
    // so rapid typing can't arrive out of order over HTTP/2.
    function sendInput(data) {
      if (!selected || !writable || !data) return;
      pendingInput += data;
      flushInput();
    }
    async function flushInput() {
      if (flushing || !pendingInput) return;
      flushing = true;
      const sessionId = selected;
      const data = pendingInput;
      pendingInput = '';
      const response = await control({ type: 'input', sessionId, data });
      flushing = false;
      if (response && response.status === 403) {
        // Another device took control of this session.
        writable = false;
        pendingInput = '';
        lease.textContent = 'view only';
      } else if (pendingInput && writable) {
        flushInput();
      }
    }
    function renderWorkspace(data) {
      const active = selected;
      sessions.replaceChildren();
      data.projects.forEach((project) => {
        const heading = document.createElement('h3');
        heading.textContent = project.name;
        sessions.append(heading);
        project.sessions.forEach((session) => {
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
    }
    function onMessage(event) {
      const message = JSON.parse(event.data);
      if (message.type === 'workspace') renderWorkspace(message.data);
      if (message.type === 'screen' && message.data.sessionId === selected) {
        terminal.textContent = message.data.lines.join('\n');
      }
    }
    terminal.addEventListener('keydown', (event) => {
      if (!writable) return;
      const special = {
        Enter:'\r', Backspace:'\u007f', Tab:'\t', Escape:'\u001b',
        ArrowUp:'\u001b[A', ArrowDown:'\u001b[B', ArrowRight:'\u001b[C', ArrowLeft:'\u001b[D'
      };
      let data = special[event.key];
      if (!data && event.ctrlKey && event.key.length === 1) {
        data = String.fromCharCode(event.key.toUpperCase().charCodeAt(0) - 64);
      } else if (!data && event.key.length === 1 && !event.metaKey) {
        data = event.key;
      }
      if (data) { event.preventDefault(); sendInput(data); }
    });
    document.querySelectorAll('#toolbar button').forEach((button) => {
      button.onclick = () => sendInput(TOOLBAR_KEYS[button.dataset.key]);
    });
    document.querySelector('#input-form').onsubmit = (event) => {
      event.preventDefault();
      if (input.value) sendInput(input.value + '\r');
      input.value = '';
      terminal.focus();
    };
    openStream();
    """#
}
