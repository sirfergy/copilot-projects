import assert from "node:assert/strict";
import test from "node:test";
import vm from "node:vm";

import { bindings, plain, readFragment } from "./support/fragments.mjs";

const source = readFragment("main");

function section(startMarker, endMarker) {
  const start = source.indexOf(startMarker);
  const end = source.indexOf(endMarker, start);
  assert.notEqual(start, -1, `missing ${startMarker}`);
  assert.notEqual(end, -1, `missing ${endMarker}`);
  return source.slice(start, end);
}

function elicitationHelpers(globals = {}) {
  const context = vm.createContext({
    URL,
    setTimeout,
    clearTimeout,
    ...globals,
  });
  vm.runInContext(
    section("const ELICITATION_MAX_FIELDS", "function safeWebURL"),
    context,
    { filename: "main-elicitation-helpers.js" }
  );
  return {
    context,
    ...bindings(context, [
      "parseElicitationForm",
      "elicitationAccepts",
      "validatedElicitationContent",
    ]),
  };
}

test("agent choice fields accept non-empty Other answers while MCP stays closed", () => {
  const { parseElicitationForm, validatedElicitationContent } =
    elicitationHelpers();
  const schema = {
    type: "object",
    required: ["fruit"],
    properties: {
      fruit: {
        type: "string",
        oneOf: [
          { const: "apple", title: "Apple" },
          { const: "pear", title: "Pear" },
        ],
      },
      drink: {
        type: "string",
        enum: ["water", "coffee"],
      },
    },
  };
  const agent = parseElicitationForm(schema, true);
  const mcp = parseElicitationForm(schema, false);

  assert.deepEqual(
    plain(
      validatedElicitationContent(
        agent,
        { fruit: "banana", drink: "tea" },
        new Set(["fruit", "drink"])
      )
    ),
    { fruit: "banana", drink: "tea" }
  );
  assert.equal(
    validatedElicitationContent(agent, { fruit: "" }, new Set(["fruit"])),
    null,
    "an empty Other answer is not valid"
  );
  assert.equal(
    validatedElicitationContent(
      mcp,
      { fruit: "banana", drink: "tea" },
      new Set(["fruit", "drink"])
    ),
    null,
    "MCP forms remain bound to their schema choices"
  );

  const emptyOption = parseElicitationForm({
    type: "object",
    properties: {
      answer: { type: "string", enum: ["", "yes"] },
    },
  }, true);
  assert.equal(
    validatedElicitationContent(
      emptyOption,
      { answer: "" },
      new Set(["answer"]),
      new Set(["answer"])
    ),
    null,
    "a blank Other answer is invalid even when empty string is a declared option"
  );
  assert.deepEqual(
    plain(validatedElicitationContent(
      emptyOption,
      { answer: "" },
      new Set(["answer"])
    )),
    { answer: "" },
    "the declared empty-string option remains selectable"
  );
});

test("Other uses index state and clears when a suggested choice is selected", () => {
  class Element {
    constructor(tagName) {
      this.tagName = tagName;
      this.children = [];
      this.attributes = {};
      this.hidden = false;
      this.selectedIndex = 0;
      this.value = "";
      this.focused = false;
    }
    append(...children) {
      this.children.push(...children);
    }
    prepend(child) {
      this.children.unshift(child);
    }
    setAttribute(name, value) {
      this.attributes[name] = value;
    }
    focus() {
      this.focused = true;
    }
  }

  const document = { createElement: (tagName) => new Element(tagName) };
  const { context } = elicitationHelpers({ document });
  vm.runInContext(
    section("function elicitationValuesEqual", "function buildElicitationField"),
    context,
    { filename: "main-elicitation-controls.js" }
  );
  const { buildElicitationChoiceSelect, buildElicitationControl } = bindings(context, [
    "buildElicitationChoiceSelect",
    "buildElicitationControl",
  ]);
  const entry = {
    values: { fruit: "apple" },
    touched: new Set(),
    customChoiceFields: new Set(),
    controlSyncers: [],
    refresh() {},
  };
  const field = {
    key: "fruit",
    title: "Fruit",
    kind: {
      type: "stringOneOf",
      choices: [{ value: "apple", title: "Apple" }],
    },
  };
  entry.form = { allowFreeformChoices: true };
  const control = buildElicitationChoiceSelect(
    entry,
    field,
    "fruit-control",
    [{ value: "apple", title: "Apple" }],
    true
  );
  const [select, label, textarea] = control.children;

  assert.deepEqual(select.children.map((option) => option.textContent), [
    "Apple",
    "Other",
  ]);
  assert.equal(label.textContent, "Fruit, other answer");

  select.selectedIndex = 1;
  select.onchange();
  assert.equal(entry.values.fruit, "");
  assert.equal(textarea.hidden, false);
  assert.equal(textarea.focused, true);

  textarea.value = "apple";
  textarea.oninput();
  entry.controlSyncers[0]();
  assert.equal(entry.values.fruit, "apple");
  assert.equal(textarea.value, "apple");

  select.selectedIndex = 0;
  select.onchange();
  assert.equal(entry.values.fruit, "apple");
  assert.equal(entry.customChoiceFields.has("fruit"), false);
  assert.equal(textarea.hidden, true);

  const booleanControl = buildElicitationControl(
    entry,
    { key: "enabled", title: "Enabled", kind: { type: "bool" } },
    "enabled-control"
  );
  assert.deepEqual(
    booleanControl.children[0].children.map((option) => option.textContent),
    ["Not set", "True", "False"],
    "agent forms do not add Other to non-choice fields"
  );
});
