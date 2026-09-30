// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html";
// Establish Phoenix Socket and LiveView configuration.
import { Socket } from "phoenix";
import { LiveSocket } from "phoenix_live_view";
import topbar from "../vendor/topbar";
import mermaid from "mermaid";

import { EditorView, basicSetup } from "codemirror";
import { toggleComment } from "@codemirror/commands";
import { Compartment } from "@codemirror/state";
import { keymap } from "@codemirror/view";
import {
  sql,
  PostgreSQL,
  SQLite,
  MySQL,
  StandardSQL,
} from "@codemirror/lang-sql";
import { vim, Vim } from "@replit/codemirror-vim";
import { oneDark } from "@codemirror/theme-one-dark";
import {
  abcdef,
  abyss,
  androidStudio,
  andromeda,
  basicDark,
  basicLight,
  catppuccinMocha,
  cobalt2,
  forest,
  githubDark,
  githubLight,
  gruvboxDark,
  gruvboxLight,
  highContrastDark,
  highContrastLight,
  materialDark,
  materialLight,
  materialOcean,
  monokai,
  nord,
  palenight,
  solarizedDark,
  solarizedLight,
  synthwave84,
  tokyoNightDay,
  tokyoNightStorm,
  volcano,
  vsCodeDark,
  vsCodeLight,
} from "@fsegurai/codemirror-theme-bundle";
import {
  moveCompletionSelection,
  acceptCompletion,
} from "@codemirror/autocomplete";
import { format } from "sql-formatter";

const editorThemes = {
  default: [],
  oneDark,
  abcdef,
  abyss,
  androidStudio,
  andromeda,
  basicDark,
  basicLight,
  catppuccinMocha,
  cobalt2,
  forest,
  githubDark,
  githubLight,
  gruvboxDark,
  gruvboxLight,
  highContrastDark,
  highContrastLight,
  materialDark,
  materialLight,
  materialOcean,
  monokai,
  nord,
  palenight,
  solarizedDark,
  solarizedLight,
  synthwave84,
  tokyoNightDay,
  tokyoNightStorm,
  volcano,
  vsCodeDark,
  vsCodeLight,
};

const formatDialects = {
  postgres: "postgresql",
  sqlite: "sqlite",
  mysql: "mysql",
};

function getEditorQuery(editorView) {
  const selection = editorView.state.selection.main;
  if (selection.from !== selection.to) {
    return editorView.state.doc
      .toString()
      .substring(selection.from, selection.to);
  }
  return editorView.state.doc.toString();
}

function formatSQL(editorView, from, to) {
  const { state } = editorView;

  if (from === undefined || to === undefined) {
    const sel = state.selection.main;
    if (sel.from !== sel.to) {
      from = sel.from;
      to = sel.to;
    } else {
      from = 0;
      to = state.doc.length;
    }
  }

  const formatted = format(state.sliceDoc(from, to), {
    language: formatDialects[window.dbType] || "sql",
    indent: "  ",
    tabWidth: 2,
    keywordCase: "upper",
    linesBetweenQueries: 1,
  });
  editorView.dispatch({ changes: { from, to, insert: formatted } });
}

Vim.defineEx("format", "", (cm, params) => {
  const view = cm.cm6;
  if (params.line !== undefined && params.lineEnd !== undefined) {
    const from = view.state.doc.line(params.line + 1).from;
    const to = view.state.doc.line(params.lineEnd + 1).to;
    formatSQL(view, from, to);
  } else {
    formatSQL(view);
  }
});

Vim.defineAction("toggle-comment", (cm) => {
  toggleComment(cm.cm6);
});

Vim.mapCommand("gcc", "action", "toggle-comment", {}, { context: "normal" });
Vim.mapCommand("gc", "action", "toggle-comment", {}, { context: "visual" });

const csrfToken = document
  .querySelector("meta[name='csrf-token']")
  .getAttribute("content");
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: { _csrf_token: csrfToken },
  hooks: {
    SQLEditor: {
      mounted() {
        const that = this;
        const sqlExtensionCompartment = new Compartment();
        const vimCompartment = new Compartment();
        const themeCompartment = new Compartment();
        // HACK: allow to load schema after receiving its value from
        // server once the database was inspected
        window.sqlExtensionCompartment = sqlExtensionCompartment;
        window.vimCompartment = vimCompartment;

        Vim.defineEx("tabnext", "tabn", () => {
          that.pushEvent("next-session", {});
        });

        Vim.defineEx("tabprev", "tabp", () => {
          that.pushEvent("prev-session", {});
        });

        Vim.map("gt", ":tabnext<CR>", "normal");
        Vim.map("gT", ":tabprev<CR>", "normal");

        function keymaps() {
          return keymap.of([
            {
              key: "Tab",
              run: acceptCompletion,
            },
            {
              key: "Ctrl-n",
              run: moveCompletionSelection(true),
            },
            {
              key: "Ctrl-p",
              run: moveCompletionSelection(false),
            },
            {
              key: "Mod-Shift-f",
              run() {
                formatSQL(view);
                return true;
              },
            },
            {
              key: "Mod-Enter",
              run() {
                that.pushEvent("run-query", { query: getEditorQuery(view) });
                return true;
              },
            },
          ]);
        }

        const editorMode = localStorage.getItem("editor-mode") || "vim";

        window.editorThemeLight = this.el.dataset.editorThemeLight || "default";
        window.editorThemeDark = this.el.dataset.editorThemeDark || "default";

        const appTheme =
          document.documentElement.getAttribute("data-theme") || "light";
        const initialTheme =
          appTheme === "dark"
            ? window.editorThemeDark
            : window.editorThemeLight;

        const view = new EditorView({
          // because this element is a textarea we pass its content
          // when initializing the editor
          doc: this.el.value,
          parent: document.getElementById("editor"),
          extensions: [
            vimCompartment.of(editorMode === "vim" ? vim() : []),
            keymaps(),
            basicSetup,
            EditorView.theme({
              ".cm-content": { fontFamily: '"JetBrains Mono", monospace' },
              ".cm-gutters": { fontFamily: '"JetBrains Mono", monospace' },
            }),
            sqlExtensionCompartment.of(sql({})),
            EditorView.updateListener.of((updateView) => {
              if (!updateView.docChanged) return;
              that.el.value = updateView.state.doc.toString();
              that.pushEvent("validate", {
                _target: ["session", "query"],
                session: { query: updateView.state.doc.toString() },
              });
            }),
            themeCompartment.of(editorThemes[initialTheme] || []),
          ],
        });

        // HACK: expose view so we can use it on load-new-query event
        // to reset editor content
        window.view = view;
        window.themeCompartment = themeCompartment;

        this._themeListener = (e) => {
          const dark = e.detail.theme === "dark";
          const theme = dark ? window.editorThemeDark : window.editorThemeLight;
          view.dispatch({
            effects: themeCompartment.reconfigure(editorThemes[theme] || []),
          });
        };
        window.addEventListener("theme-changed", this._themeListener);

        view.focus();
      },
      destroyed() {
        if (this._themeListener) {
          window.removeEventListener("theme-changed", this._themeListener);
        }
        if (window.view) {
          window.view.destroy();
          window.view = null;
        }
        window.sqlExtensionCompartment = null;
        window.vimCompartment = null;
        window.themeCompartment = null;
      },
    },
    CommandPalette: {
      mounted() {
        this.setupInput();
      },
      updated() {
        this.setupInput();

        const selected = this.el.querySelector("[data-selected]");
        if (selected) selected.scrollIntoView({ block: "nearest" });
      },
      setupInput() {
        const input = this.el.querySelector("#command-palette-input");
        if (!input) return;

        if (document.activeElement !== input) {
          input.focus();
        }

        // Only attach listener once
        if (!input._paletteKeydown) {
          input._paletteKeydown = true;
          input.addEventListener("keydown", (e) => {
            if (
              e.key === "ArrowUp" ||
              e.key === "ArrowDown" ||
              (e.ctrlKey && (e.key === "n" || e.key === "p"))
            ) {
              e.preventDefault();
            }
          });
        }
      },
    },
    EditorThemeSelect: {
      applyTheme() {
        const key = this.el.dataset.themeKey;
        const theme = this.el.value;
        if (key === "editor-theme-dark") window.editorThemeDark = theme;
        else window.editorThemeLight = theme;
        const appTheme =
          document.documentElement.getAttribute("data-theme") || "light";
        const isActive =
          (key === "editor-theme-dark" && appTheme === "dark") ||
          (key === "editor-theme-light" && appTheme === "light");
        if (isActive && window.view && window.themeCompartment) {
          window.view.dispatch({
            effects: window.themeCompartment.reconfigure(
              editorThemes[theme] || [],
            ),
          });
        }
      },
      mounted() {
        this.el.addEventListener("change", () => this.applyTheme());
      },
      updated() {
        this.applyTheme();
      },
    },
    AiChatInput: {
      resize() {
        this.el.style.height = "auto";
        this.el.style.height = `${this.el.scrollHeight}px`;
      },
      mounted() {
        this.el.addEventListener("input", () => this.resize());
        this.el.addEventListener("keydown", (e) => {
          if (e.key === "Enter" && !e.shiftKey && !e.isComposing) {
            e.preventDefault();
            this.el.form.requestSubmit();
          }
        });
        this.resize();
      },
      updated() {
        this.resize();
      },
    },
    AiChatScroll: {
      mounted() {
        this.scrollToBottom();
      },
      updated() {
        this.scrollToBottom();
      },
      scrollToBottom() {
        this.el.scrollTop = this.el.scrollHeight;
      },
    },
    PanelResize: {
      mounted() {
        const container = this.el;
        let activeHandle = null;
        let startX = 0;
        let startWidths = {};

        const getPanel = (id) => container.querySelector(`#panel-${id}`);

        container.querySelectorAll(".panel-resize-handle").forEach((handle) => {
          handle.addEventListener("mousedown", (e) => {
            e.preventDefault();
            activeHandle = handle;
            activeHandle.classList.add("active");
            startX = e.clientX;
            const containerWidth = container.offsetWidth;

            const sidebar = getPanel("sidebar");
            const ai = getPanel("ai");
            startWidths = {
              sidebar: sidebar
                ? (sidebar.offsetWidth / containerWidth) * 100
                : 0,
              ai: ai ? (ai.offsetWidth / containerWidth) * 100 : 0,
            };

            document.body.style.cursor = "col-resize";
            document.body.style.userSelect = "none";
          });
        });

        const onMouseMove = (e) => {
          if (!activeHandle) return;
          const containerWidth = container.offsetWidth;
          const dx = ((e.clientX - startX) / containerWidth) * 100;
          const which = activeHandle.dataset.resize;

          if (which === "sidebar") {
            const newW = Math.min(50, Math.max(10, startWidths.sidebar + dx));
            const sidebar = getPanel("sidebar");
            if (sidebar) sidebar.style.width = `${newW}%`;
          } else if (which === "ai") {
            const newW = Math.min(50, Math.max(10, startWidths.ai - dx));
            const ai = getPanel("ai");
            if (ai) ai.style.width = `${newW}%`;
          }
        };

        const onMouseUp = () => {
          if (!activeHandle) return;
          activeHandle.classList.remove("active");
          activeHandle = null;
          document.body.style.cursor = "";
          document.body.style.userSelect = "";

          const containerWidth = container.offsetWidth;
          const sidebar = getPanel("sidebar");
          const ai = getPanel("ai");
          const sidebarPct = sidebar
            ? parseFloat(
                ((sidebar.offsetWidth / containerWidth) * 100).toFixed(1),
              )
            : 0;
          const aiPct = ai
            ? parseFloat(((ai.offsetWidth / containerWidth) * 100).toFixed(1))
            : 0;

          this.pushEvent("save-panel-widths", {
            sidebar: sidebarPct,
            ai: aiPct,
          });
        };

        document.addEventListener("mousemove", onMouseMove);
        document.addEventListener("mouseup", onMouseUp);

        this.cleanup = () => {
          document.removeEventListener("mousemove", onMouseMove);
          document.removeEventListener("mouseup", onMouseUp);
        };
      },
      destroyed() {
        if (this.cleanup) this.cleanup();
      },
    },
    RunQueryButton: {
      mounted() {
        this.el.addEventListener("click", (e) => {
          if (!window.view) return;
          e.preventDefault();
          this.pushEvent("run-query", { query: getEditorQuery(window.view) });
        });
      },
    },
    AutoHideFlash: {
      mounted() {
        this.timer = setTimeout(() => {
          this.el.style.transition = "opacity 0.15s ease-out";
          this.el.style.opacity = "0";
          setTimeout(() => {
            this.pushEvent("lv:clear-flash", {});
            this.el.remove();
          }, 150);
        }, 2000);
      },
      destroyed() {
        clearTimeout(this.timer);
      },
    },
    OnboardingModal: {
      mounted() {
        this.handleKeydown = (e) => {
          if (e.key === "Enter" || e.key === "ArrowRight") {
            e.preventDefault();
            e.stopPropagation();
            this.pushEventTo(this.el, "next-step", {});
          } else if (e.key === "ArrowLeft") {
            e.preventDefault();
            e.stopPropagation();
            this.pushEventTo(this.el, "prev-step", {});
          } else if (e.key === "Escape") {
            e.preventDefault();
            e.stopPropagation();
            this.pushEventTo(this.el, "skip-onboarding", {});
          }
        };
        document.addEventListener("keydown", this.handleKeydown, true);
      },
      destroyed() {
        document.removeEventListener("keydown", this.handleKeydown, true);
      },
    },
    CellEditor: {
      mounted() {
        const input = this.el.querySelector("input[name='value']");
        if (input) {
          input.focus();
          input.select();
          input.addEventListener("keydown", (e) => {
            if (e.key === "Escape") {
              e.preventDefault();
              this.pushEventTo(this.el, "cancel-edit", {});
            } else if (e.key === "Enter" && (e.ctrlKey || e.metaKey)) {
              // Ctrl+Enter sets NULL
              e.preventDefault();
              this.pushEventTo(this.el, "save-cell-null", {});
            }
          });
        }
      },
    },
    MermaidDiagram: {
      mounted() {
        const isDark =
          document.documentElement.getAttribute("data-theme") === "dark";
        mermaid.initialize({
          startOnLoad: false,
          theme: isDark ? "dark" : "default",
        });
        this.renderDiagram();
      },
      updated() {
        this.renderDiagram();
      },
      async renderDiagram() {
        const definition = this.el.getAttribute("data-definition");
        if (!definition) return;
        try {
          const { svg } = await mermaid.render("mermaid-svg", definition);
          this.el.innerHTML = svg;
        } catch (e) {
          this.el.innerHTML = `<div class="p-4 text-xs" style="color: var(--text-tertiary);">Failed to render diagram.</div>`;
        }
      },
    },
  },
  metadata: {
    keydown: (e, _el) => {
      return {
        key: e.key,
        metaKey: e.metaKey,
        ctrlKey: e.ctrlKey,
      };
    },
  },
});

window.addEventListener("phx:load-query", ({ detail }) => {
  // this will be triggered when a new session is loaded in server, so
  // we need to reset SQL editor with new session's query
  if (!window.view) return;
  const newState = window.view.state.update({
    changes: {
      from: 0,
      to: window.view.state.doc.length,
      insert: detail.query,
    },
  });
  window.view.dispatch(newState);
});

window.addEventListener("phx:append-query", ({ detail }) => {
  if (!window.view) return;
  const pos = window.view.state.doc.length;
  const text = (pos > 0 ? "\n" : "") + detail.query;
  window.view.dispatch({
    changes: { from: pos, insert: text },
    selection: { anchor: pos + text.length },
  });
  window.view.focus();
});

// Refocus the SQL editor (e.g. after closing command palette)
window.addEventListener("phx:refocus-editor", () => {
  if (window.view) window.view.focus();
});

window.addEventListener("phx:load-schema", ({ detail: { schema, type } }) => {
  if (!window.view || !window.sqlExtensionCompartment) return;
  window.dbType = type;
  let dialect = StandardSQL;
  if (type === "postgres") dialect = PostgreSQL;
  if (type === "sqlite") dialect = SQLite;
  if (type === "mysql") dialect = MySQL;

  window.view.dispatch({
    effects: window.sqlExtensionCompartment.reconfigure(
      sql({ schema: schema, dialect: dialect }),
    ),
  });
});

// Download file without navigating away
window.addEventListener("phx:open-url", (event) => {
  const a = document.createElement("a");
  a.href = event.detail.url;
  a.download = "";
  document.body.appendChild(a);
  a.click();
  a.remove();
});

// Copy to clipboard handler
window.addEventListener("phx:copy", (event) => {
  if (event.detail?.text) {
    navigator.clipboard.writeText(event.detail.text);
  }
});

// Cell detail modal
(() => {
  let cellDetailState = { raw: "", isJson: false, showFormatted: true };

  function tryFormatJson(str) {
    try {
      return JSON.stringify(JSON.parse(str), null, 2);
    } catch {
      return null;
    }
  }

  function updateToggleButtons() {
    const fmtBtn = document.getElementById("cell-detail-formatted-btn");
    const rawBtn = document.getElementById("cell-detail-raw-btn");
    if (!fmtBtn || !rawBtn) return;

    const activeStyle = "background: var(--focus-color); color: white;";
    const inactiveStyle =
      "background: var(--bg-tertiary); color: var(--text-secondary); border: 0.5px solid var(--border-medium);";
    fmtBtn.style.cssText = cellDetailState.showFormatted
      ? activeStyle
      : inactiveStyle;
    rawBtn.style.cssText = cellDetailState.showFormatted
      ? inactiveStyle
      : activeStyle;
  }

  function updateContent() {
    const content = document.getElementById("cell-detail-content");
    if (!content) return;
    content.textContent =
      cellDetailState.showFormatted && cellDetailState.isJson
        ? tryFormatJson(cellDetailState.raw) || cellDetailState.raw
        : cellDetailState.raw;
  }

  // Show modal on cell click
  document.addEventListener("click", (event) => {
    const cell = event.target.closest(".cell-expandable[data-full-value]");
    if (!cell) return;

    event.stopPropagation();

    const raw = cell.getAttribute("data-full-value");
    const isJson = cell.classList.contains("cell-json");
    const toggle = document.getElementById("cell-detail-format-toggle");
    const modal = document.getElementById("cell-detail-modal");
    if (!modal) return;

    cellDetailState = { raw, isJson, showFormatted: true };

    if (toggle) {
      toggle.style.display = isJson ? "flex" : "none";
    }

    updateToggleButtons();
    updateContent();
    liveSocket.execJS(modal, modal.getAttribute("data-show-modal"));
  });

  // Toggle buttons
  document.addEventListener("click", (event) => {
    if (event.target.closest("#cell-detail-formatted-btn")) {
      cellDetailState.showFormatted = true;
      updateToggleButtons();
      updateContent();
    } else if (event.target.closest("#cell-detail-raw-btn")) {
      cellDetailState.showFormatted = false;
      updateToggleButtons();
      updateContent();
    }
  });

  // Copy button
  document.addEventListener("click", (event) => {
    const btn = event.target.closest("#cell-detail-copy-btn");
    if (!btn) return;

    const content = document.getElementById("cell-detail-content");
    if (!content) return;

    navigator.clipboard.writeText(content.textContent).then(() => {
      const label = btn.querySelector("span");
      if (label) {
        label.textContent = "Copied!";
        setTimeout(() => {
          label.textContent = "Copy";
        }, 1500);
      }
    });
  });
})();

// Download diagram as PNG
document.addEventListener("click", (event) => {
  const btn = event.target.closest("#download-diagram-btn");
  if (!btn) return;

  const svg = document.querySelector("#mermaid-diagram svg");
  if (!svg) return;

  const svgData = new XMLSerializer().serializeToString(svg);
  const canvas = document.createElement("canvas");
  const ctx = canvas.getContext("2d");
  const img = new Image();

  img.onload = () => {
    const scale = 2;
    canvas.width = img.width * scale;
    canvas.height = img.height * scale;
    ctx.scale(scale, scale);
    ctx.fillStyle =
      getComputedStyle(document.documentElement).getPropertyValue(
        "--bg-primary",
      ) || "#fff";
    ctx.fillRect(0, 0, img.width, img.height);
    ctx.drawImage(img, 0, 0);

    const a = document.createElement("a");
    const dbName = btn.getAttribute("data-database-name") || "schema";
    a.download = `${dbName}-diagram.png`;
    a.href = canvas.toDataURL("image/png");
    a.click();
  };

  img.src = `data:image/svg+xml;charset=utf-8,${encodeURIComponent(svgData)}`;
});

// Open settings modal from command palette
window.addEventListener("phx:open-settings-modal", () => {
  const modal = document.getElementById("settings-modal");
  if (modal) {
    liveSocket.execJS(modal, modal.getAttribute("data-show-modal"));
  }
});

// Open the AI usage report after its data has been refreshed
window.addEventListener("phx:open-ai-usage-modal", () => {
  const modal = document.getElementById("ai-usage-modal");
  if (modal) {
    liveSocket.execJS(modal, modal.getAttribute("data-show-modal"));
  }
});

// Focus AI chat input when panel opens
window.addEventListener("phx:focus-ai-chat", () => {
  requestAnimationFrame(() => {
    const input = document.getElementById("ai-chat-input");
    if (input) input.focus();
  });
});

// Hide settings modal (e.g. when opening welcome tutorial from settings)
window.addEventListener("phx:hide-settings-modal", () => {
  const modal = document.getElementById("settings-modal");
  if (modal?.getAttribute("data-cancel")) {
    liveSocket.execJS(modal, modal.getAttribute("data-cancel"));
  }
});

// Open shortcuts modal
window.addEventListener("phx:open-shortcuts-modal", () => {
  const modal = document.getElementById("shortcuts-modal");
  if (modal) {
    liveSocket.execJS(modal, modal.getAttribute("data-show-modal"));
  }
});

window.addEventListener("phx:open-diagram-modal", () => {
  const modal = document.getElementById("diagram-modal");
  if (modal) {
    liveSocket.execJS(modal, modal.getAttribute("data-show-modal"));
  }
});

// Forward palette actions by clicking existing buttons
window.addEventListener("phx:palette-exec", (event) => {
  const { event: name, value } = event.detail;
  const btn = document.querySelector(
    `[phx-click='${name}']${value ? `[phx-value-tab='${value}']` : ""}`,
  );
  if (btn) btn.click();
});

// Show progress bar on live navigation and form submits
topbar.config({ barColors: { 0: "#29d" }, shadowColor: "rgba(0, 0, 0, .3)" });
window.addEventListener("phx:page-loading-start", (_info) => topbar.show(300));
window.addEventListener("phx:page-loading-stop", (_info) => topbar.hide());

// connect if there are any LiveViews on the page
liveSocket.connect();

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket;

// Global keyboard shortcuts
// Use capture phase so it fires before CodeMirror's Vim mode consumes keys
function isInputFocused() {
  const el = document.activeElement;
  if (!el) return false;
  const tag = el.tagName;
  return (
    tag === "INPUT" ||
    tag === "TEXTAREA" ||
    tag === "SELECT" ||
    el.isContentEditable ||
    el.closest(".cm-editor")
  );
}

function pushLiveEvent(event) {
  const main = document.querySelector("[data-phx-main]");
  if (!main) return;

  liveSocket.execJS(
    main,
    JSON.stringify([["push", { event: event, value: {} }]]),
  );
}

document.addEventListener(
  "keydown",
  (e) => {
    const mod = e.metaKey || e.ctrlKey;

    // CMD+K / Ctrl+K — Command palette
    if (mod && e.key === "k") {
      e.preventDefault();
      e.stopPropagation();
      const trigger = document.getElementById("command-palette-trigger");
      if (trigger) trigger.click();
      return;
    }

    // Cmd+' Ctrl+' — Focus editor
    if (mod && e.key === "'") {
      e.preventDefault();
      e.stopPropagation();
      if (window.view) window.view.focus();
      return;
    }

    // CMD+B — Toggle AI panel
    if (mod && !e.shiftKey && e.key === "b") {
      e.preventDefault();
      e.stopPropagation();
      pushLiveEvent("toggle-ai-panel");
      return;
    }

    // / — Focus search input on databases page
    if (e.key === "/" && !mod && !isInputFocused()) {
      const searchInput = document.getElementById("search-connections");
      if (searchInput) {
        e.preventDefault();
        searchInput.focus();
      }
      return;
    }

    // ? — Keyboard shortcuts (only when not typing in an input)
    if (e.key === "?" && !mod && !isInputFocused()) {
      e.preventDefault();
      const modal = document.getElementById("shortcuts-modal");
      if (modal) {
        liveSocket.execJS(modal, modal.getAttribute("data-show-modal"));
      }
    }
  },
  true,
);

// Theme management using data-theme attribute
function resolveTheme(preference) {
  if (preference === "system" || !preference) {
    return window.matchMedia("(prefers-color-scheme: dark)").matches
      ? "dark"
      : "light";
  }
  return preference;
}

function applyTheme(preference) {
  const resolved = resolveTheme(preference);
  document.documentElement.setAttribute("data-theme", resolved);
  localStorage.setItem("theme", preference);
  window.dispatchEvent(
    new CustomEvent("theme-changed", { detail: { theme: resolved } }),
  );
}

// Apply initial theme
const savedTheme = localStorage.getItem("theme") || "system";
applyTheme(savedTheme);

// Listen for system preference changes
window
  .matchMedia("(prefers-color-scheme: dark)")
  .addEventListener("change", () => {
    const current = localStorage.getItem("theme") || "system";
    if (current === "system") {
      applyTheme("system");
    }
  });

// Toggle theme on button click
const themeToggle = document.getElementById("theme-toggle");
themeToggle.addEventListener("click", () => {
  const current = document.documentElement.getAttribute("data-theme");
  const next = current === "dark" ? "light" : "dark";
  applyTheme(next);
});

// Font size management — restore saved size on load
const savedFontSize = localStorage.getItem("font-size");
if (savedFontSize) {
  const presets = { xs: true, sm: true, md: true, lg: true, xl: true };
  if (presets[savedFontSize]) {
    document.documentElement.setAttribute("data-font-size", savedFontSize);
  } else {
    document.documentElement.style.setProperty(
      "--font-size-base",
      `${savedFontSize}px`,
    );
  }
}

window.addEventListener("phx:set-font-size", (event) => {
  const size = event.detail.size;
  const presets = {
    xs: "11px",
    sm: "12px",
    md: "14px",
    lg: "16px",
    xl: "18px",
  };

  if (presets[size]) {
    document.documentElement.setAttribute("data-font-size", size);
    document.documentElement.style.removeProperty("--font-size-base");
  } else {
    // Custom numeric value
    document.documentElement.removeAttribute("data-font-size");
    document.documentElement.style.setProperty("--font-size-base", `${size}px`);
  }
  localStorage.setItem("font-size", size);
});

// Editor mode (vim/standard)
window.addEventListener("phx:set-editor-mode", (event) => {
  const mode = event.detail.mode;
  localStorage.setItem("editor-mode", mode);

  if (window.view && window.vimCompartment) {
    window.view.dispatch({
      effects: window.vimCompartment.reconfigure(mode === "vim" ? vim() : []),
    });
  }
});

// this only work when running through Tauri web view
if (window.__TAURI__) {
  const { invoke } = window.__TAURI__.core;

  document.addEventListener("keydown", async (event) => {
    if (event.metaKey && event.key === "n") {
      event.preventDefault();

      await invoke("open_new_window");
    }
  });
}
