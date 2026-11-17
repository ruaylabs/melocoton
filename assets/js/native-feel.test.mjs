import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import vm from "node:vm";

const app = readFileSync(new URL("./app.js", import.meta.url), "utf8");
const css = readFileSync(new URL("../css/app.css", import.meta.url), "utf8");
const splash = readFileSync(
  new URL("../../views/main.js", import.meta.url),
  "utf8",
);

function luminance(hex) {
  const rgb = hex.match(/[\da-f]{2}/gi).map((value) => {
    const channel = parseInt(value, 16) / 255;
    return channel <= 0.04045
      ? channel / 12.92
      : ((channel + 0.055) / 1.055) ** 2.4;
  });
  return rgb[0] * 0.2126 + rgb[1] * 0.7152 + rgb[2] * 0.0722;
}

function contrast(a, b) {
  const values = [luminance(a), luminance(b)].sort((x, y) => y - x);
  return (values[0] + 0.05) / (values[1] + 0.05);
}

for (const theme of ["light", "dark"]) {
  test(`${theme}: selection and scrollbar contrast`, () => {
    const block = css.match(
      new RegExp(`\\[data-theme="${theme}"\\] \\{([^}]+)`),
    )[1];
    const token = (name) =>
      block.match(new RegExp(`--${name}:\\s*(#[\\da-f]+)`))[1];
    assert.ok(contrast(token("selection-bg"), token("selection-text")) >= 4.5);
    for (const background of ["bg-primary", "bg-secondary", "bg-tertiary"]) {
      assert.ok(contrast(token("scrollbar-thumb"), token(background)) >= 3);
      assert.ok(
        contrast(token("scrollbar-thumb-hover"), token(background)) >= 3,
      );
    }
  });
}

test("selection restrictions never apply to body", () => {
  assert.doesNotMatch(css, /body[^{}]*\{[^}]*user-select:\s*none/);
  assert.match(css, /@media \(forced-colors: active\)/);
  assert.match(css, /background-color: Highlight;/);
  assert.match(css, /all: revert;/);
});

test("context menus are restricted to Tauri chrome, with content taking precedence", () => {
  const handlers = {};
  class Element {
    constructor(content, chrome) {
      this.content = content;
      this.chrome = chrome;
    }
    closest(selector) {
      return selector.includes("input,") ? this.content : this.chrome;
    }
  }
  const source = app.slice(
    app.indexOf("// this only work when running through Tauri"),
  );
  const document = {
    addEventListener: (name, callback) => {
      handlers[name] = callback;
    },
  };
  vm.runInNewContext(source, { window: {}, document, Element });
  assert.equal(handlers.contextmenu, undefined);
  vm.runInNewContext(source, {
    window: { __TAURI__: { core: { invoke() {} } } },
    document,
    Element,
  });
  for (const [content, chrome, alreadyHandled, expected] of [
    [false, true, false, true],
    [true, true, false, false],
    [false, false, false, false],
    [false, true, true, false],
  ]) {
    let prevented = false;
    handlers.contextmenu({
      target: new Element(content, chrome),
      defaultPrevented: alreadyHandled,
      preventDefault() {
        prevented = true;
      },
    });
    assert.equal(prevented, expected);
  }
});

for (const preference of ["light", "dark", "system"]) {
  for (const systemDark of [false, true]) {
    test(`splash restores native ${preference}, system dark=${systemDark}`, async () => {
      const calls = [];
      const attributes = {};
      const frames = [];
      const timers = [];
      await vm.runInNewContext(`(async () => { ${splash} })()`, {
        window: {
          __TAURI__: {
            core: {
              async invoke(command, args) {
                calls.push([command, args]);
                return preference;
              },
            },
          },
          matchMedia: () => ({ matches: systemDark }),
        },
        localStorage: { getItem: () => "light" },
        document: {
          documentElement: {
            setAttribute(name, value) {
              attributes[name] = value;
            },
          },
        },
        requestAnimationFrame: (callback) => frames.push(callback),
        setTimeout: (callback) => timers.push(callback),
        console,
      });
      const dark =
        preference === "dark" || (preference === "system" && systemDark);
      assert.equal(attributes["data-theme"], dark ? "dark" : "light");
      assert.equal(
        calls.length,
        1,
        "window stays hidden until paint frames complete",
      );
      // Exercise the fallback for hidden windows as well as normal paint frames.
      if (systemDark) timers.shift()();
      while (frames.length) frames.shift()();
      while (timers.length) timers.shift()();
      assert.equal(calls.length, 2, "reveal is invoked only once");
      assert.equal(calls[1][0], "theme_ready");
      assert.equal(calls[1][1].preference, preference);
      assert.equal(calls[1][1].dark, dark);
    });
  }
}
