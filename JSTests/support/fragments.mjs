// Loads the shipped web-client fragments straight out of the packaged resource
// files (the same bytes `RemoteWebAssets` serves) and evaluates them in a VM
// context. Nothing here parses Swift or rewrites the assets: a test that passes
// here is a test against exactly what ships.
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import vm from "node:vm";

// .../JSTests/support/fragments.mjs -> the package root.
export const repositoryRoot = dirname(dirname(dirname(fileURLToPath(import.meta.url))));

export const webResourceDir = join(
  repositoryRoot,
  "Sources/copilot-projects/Resources/web"
);

export const trackerResourceDir = join(
  repositoryRoot,
  "Sources/CopilotProjectsCore/Resources/tracker"
);

/// The canonical wire examples shared with the Swift contract tests
/// (`ProtocolFixtures.data(named:)` reads the same files out of the
/// `CopilotProjectsProtocolFixtures` bundle). Read here by relative path so a
/// JavaScript contract test asserts against the exact same bytes without
/// needing a SwiftPM bundle.
export const fixturesDir = join(repositoryRoot, "ContractFixtures/Fixtures");

export function fixtureText(name) {
  return readFileSync(join(fixturesDir, `${name}.json`), "utf8");
}

export function fixture(name) {
  return JSON.parse(fixtureText(name));
}

/// The concatenation order `RemoteWebAssets.javascript` uses. Kept here so a
/// fragment that is added to the Swift facade but not to the resource directory
/// (or vice versa) fails a test rather than a page load.
export const fragmentOrder = [
  "markdown",
  "draft",
  "operations",
  "control-delivery",
  "session-creation",
  "terminal-image",
  "transcript",
  "main",
];

export function readFragment(name) {
  return readFileSync(join(webResourceDir, "js", `${name}.js`), "utf8");
}

export function joinJavaScriptFragments(sources) {
  return sources
    .map((source) => source.endsWith("\n") ? source.slice(0, -1) : source)
    .join("\n");
}

/// `RemoteWebAssets` drops each fragment's trailing newline and inserts one
/// newline boundary between files, so the assembled script here matches the
/// served `/app.js` byte for byte.
export function assembledJavaScript() {
  return joinJavaScriptFragments(fragmentOrder.map(readFragment));
}

/// Evaluates fragments in order in a fresh realm seeded with `globals`.
export function loadFragments(names, globals = {}) {
  const context = vm.createContext({
    console,
    URL,
    URLSearchParams,
    TextEncoder,
    TextDecoder,
    setTimeout,
    clearTimeout,
    queueMicrotask,
    ...globals,
  });
  for (const name of names) {
    vm.runInContext(readFragment(name), context, { filename: `${name}.js` });
  }
  return context;
}

/// Reads named top-level bindings out of a loaded context. `const`/`let`
/// declarations live in the realm's lexical environment rather than on its
/// global object, so they have to be evaluated by name rather than read as
/// properties.
export function bindings(context, names) {
  const result = {};
  for (const name of names) {
    result[name] = vm.runInContext(name, context, { filename: "bindings" });
  }
  return result;
}

/// Copies a value produced inside the VM realm into this one, so `deepStrictEqual`
/// (which compares prototypes) can be used on it.
export function plain(value) {
  return JSON.parse(JSON.stringify(value));
}

/// The smallest document shim the markdown renderer needs: element/text nodes
/// that record structure so assertions can inspect what was built.
export function documentShim() {
  class FakeNode {
    constructor(tagName) {
      this.tagName = tagName;
      this.children = [];
      this.attributes = {};
      this.style = { setProperty() {} };
      this.className = "";
      this._text = undefined;
    }
    append(...nodes) {
      for (const node of nodes) this.children.push(node);
    }
    setAttribute(name, value) {
      this.attributes[name] = value;
    }
    get textContent() {
      if (this._text !== undefined) return this._text;
      return this.children.map((child) => child.textContent).join("");
    }
    set textContent(value) {
      this._text = value;
      this.children = [];
    }
    countNodes() {
      return 1 + this.children.reduce(
        (sum, child) => sum + (child.countNodes ? child.countNodes() : 1),
        0
      );
    }
    findAll(tag) {
      let results = this.tagName === tag ? [this] : [];
      for (const child of this.children) {
        if (child.findAll) results = results.concat(child.findAll(tag));
      }
      return results;
    }
  }
  class FakeTextNode {
    constructor(text) {
      this._text = text;
    }
    get textContent() {
      return this._text;
    }
    countNodes() {
      return 1;
    }
  }
  return {
    FakeNode,
    document: {
      createElement: (tag) => new FakeNode(tag),
      createTextNode: (text) => new FakeTextNode(text),
    },
  };
}

/// An in-memory Storage that behaves like the browser's for the `length` /
/// `key(index)` pair the draft loader walks.
export function localStorageShim(seed = {}) {
  const entries = new Map(Object.entries(seed));
  return {
    get length() {
      return entries.size;
    },
    key(index) {
      return [...entries.keys()][index] ?? null;
    },
    getItem(key) {
      return entries.has(key) ? entries.get(key) : null;
    },
    setItem(key, value) {
      entries.set(key, String(value));
    },
    removeItem(key) {
      entries.delete(key);
    },
    clear() {
      entries.clear();
    },
    _entries: entries,
  };
}
