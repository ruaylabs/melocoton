# Melocoton

A keyboard-driven, multi-platform database client for SQLite, PostgreSQL, and MySQL. Built with Elixir/Phoenix LiveView
and packaged as a native desktop app with Tauri.

> **Melocoton** (/me.loˈko.ton/) means "peach" in Spanish. It is a power-user tool
> designed for developers and DBAs who value speed, precision, and staying in flow.

## Table of contents

- [Features](#features)
- [Installation](#installation)
- [Development](#development)
- [Desktop builds](#desktop-builds)
- [AI assistant setup](#ai-assistant-setup)
- [Keyboard shortcuts](#keyboard-shortcuts)
- [Tech stack](#tech-stack)
- [Architecture overview](#architecture-overview)

## Features

- **Keyboard-native** — every action is reachable from the keyboard; shortcut hints shown inline
- **SQL editor** — CodeMirror-powered editor with syntax highlighting, auto-completion, and optional Vim mode
- **Transaction support** — interactive transactions with explicit commit/rollback control
- **Query plans** — tree charts for PostgreSQL EXPLAIN (text/JSON), MySQL tabular/JSON/TREE,
  and SQLite EXPLAIN QUERY PLAN, with relative hotspots and engine-specific scan/sort warnings.
  [Plan formats and highlighting semantics](docs/query-plans.md); raw results are preserved.
- **Table explorer** — browse schemas, tables, indexes, columns, and foreign keys
- **Multiple databases** — connect to several databases and switch between them instantly
- **Connection groups** — organize databases by project, environment, or team with color-coded labels
- **AI assistant** — natural language to SQL with schema-aware chat; supports Anthropic, OpenAI, OpenRouter, MiniMax,
  and local models via Ollama
- **Data export** — export query results to CSV or Excel
- **Query history** — search and re-run past queries
- **Cross-platform desktop app** — native builds for macOS, Linux, and Windows

## Installation

### Homebrew (macOS)

```bash
brew install --cask ruaylabs/tap/melocoton
```

The cask is maintained in the [Ruaylabs Homebrew tap](https://github.com/ruaylabs/homebrew-tap).

### Manual download

Download the latest release for your platform from the [Releases](https://github.com/ruaylabs/melocoton/releases) page:

| Platform | Installer                   |
|----------|-----------------------------|
| macOS    | `.dmg`                      |
| Linux    | `.deb`, `.rpm`, `.AppImage` |
| Windows  | `.msi`, `.exe` (NSIS)       |

No additional runtime is required — the desktop app bundles the Elixir VM via Burrito.

## Development

### Requirements

- [mise](https://mise.jdx.dev/getting-started.html) — manages Elixir, Erlang, and Node.js versions
- [just](https://github.com/casey/just) — command runner (see `justfile`)
- [Rust](https://rustup.rs/) — required only for desktop builds (Tauri)

### Quick start

```bash
# Install tool versions (Elixir, Node, etc.)
mise install

# Install dependencies and set up the local SQLite database
just setup

# Start the dev server at http://localhost:4000
just dev
```

### Common tasks

```bash
just test              # Run the test suite
just ci                # Full CI check (format + audit + tests + coverage)
just fmt               # Format all code
just tauri-dev         # Tauri dev mode with hot reload
just db-migrate        # Run pending Ecto migrations
just db-reset          # Drop, create, migrate, and seed the DB
just release           # Full desktop app build (macOS / Linux)
```

Run `just --list` to see all available recipes.

## Desktop builds

The desktop app is built with Tauri and packages the Elixir runtime via Burrito.

### macOS / Linux

```bash
just release
# or directly:
bash build.sh
```

### Windows

Requires [zig](https://ziglang.org/) and `xz` in your PATH (Burrito dependencies).

```powershell
powershell -File build.ps1
```

## AI assistant setup

The AI assistant can be configured from the in-app **Settings** panel.

Supported providers:

| Provider   | Required configuration                    |
|------------|-------------------------------------------|
| Anthropic  | API key                                   |
| OpenAI     | API key                                   |
| OpenRouter | API key                                   |
| MiniMax    | API key                                   |
| Ollama     | Base URL (e.g., `http://localhost:11434`) |

Select your preferred provider and model, then start a chat from any database connection. The assistant is schema-aware
— it can read your table definitions to generate more accurate SQL.

## Keyboard shortcuts

Melocoton is designed to be used without leaving the keyboard.

### Global

| Shortcut       | Action                  |
|----------------|-------------------------|
| `Ctrl/Cmd + K` | Open command palette    |
| `Ctrl/Cmd + ,` | Open settings           |
| `Ctrl/Cmd + B` | Toggle AI panel         |
| `Ctrl/Cmd + N` | New window              |
| `?`            | Show keyboard shortcuts |

### SQL editor

| Shortcut               | Action                           |
|------------------------|----------------------------------|
| `Ctrl/Cmd + '`         | Focus editor                     |
| `Ctrl/Cmd + Enter`     | Run query (selection or all)     |
| `Ctrl/Cmd + S`         | Save query to file               |
| `Ctrl/Cmd + Shift + F` | Format SQL                       |
| `Tab`                  | Accept autocomplete suggestion   |
| `Ctrl + N`             | Next autocomplete suggestion     |
| `Ctrl + P`             | Previous autocomplete suggestion |

### Databases page

| Shortcut | Action       |
|----------|--------------|
| `/`      | Focus search |

> Shortcut hints are shown inline throughout the interface. Press `?` anywhere to see the full list.

## Tech stack

| Layer     | Technology                           |
|-----------|--------------------------------------|
| Backend   | Elixir, Phoenix LiveView             |
| Frontend  | LiveView, Tailwind CSS, CodeMirror 6 |
| Desktop   | Tauri (Rust)                         |
| Databases | Postgrex, Exqlite, MyXQL             |
| Packaging | Burrito (embeds Elixir runtime)      |

## Architecture overview

```
┌──────────────────────────────────────────────┐
│  Tauri Desktop Window (Rust)                 │
│  ┌─────────────────────────────────────────┐ │
│  │  WebView → Phoenix LiveView UI          │ │
│  └─────────────────────────────────────────┘ │
└──────────────────────────────────────────────┘
                    │
                    ▼
         ┌─────────────────────┐
         │  Burrito Sidecar    │
         │  (Embedded BEAM VM) │
         └─────────────────────┘
                    │
    ┌───────────────┼──────────────────────┐
    ▼               ▼                      ▼
┌──────────┐  ┌──────────┐         ┌──────────────┐
│  SQLite  │  │   Pool   │         │  AI Models   │
│  (local  │  │  (lazy   │         │  (Anthropic, │
│   meta   │  │   per-   │         │   OpenAI,    │
│  store)  │  │  database│         │   Ollama...) │
└──────────┘  │   cache) │         └──────────────┘
              └────┬─────┘
                   │
    ┌──────────────┼──────────────┐
    ▼              ▼              ▼
┌────────┐  ┌──────────┐  ┌──────────┐
│SQLite  │  │PostgreSQL│  │  MySQL   │
│(user)  │  │ (user)   │  │  (user)  │
└────────┘  └──────────┘  └──────────┘
```

Melocoton is a desktop client — it does not host your data. The Elixir/Phoenix app runs as a Tauri sidecar and uses a
local SQLite database only for its own metadata (saved connections, groups, query history, settings). User-configured
database connections (SQLite, PostgreSQL, or MySQL) are reached through a lazily initialized connection pool.

## License

MIT
