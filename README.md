# Pluto Pair

Pluto Pair is a Codex plugin for working with [Pluto.jl](https://plutojl.org/) notebooks from an agent. It exposes MCP tools for two workflows:

- **Live pairing** with a Pluto server that is already open in the browser.
- **Headless checks** that open notebooks in a plugin-owned Julia session for testing, state inspection, and HTML export.

The included `skills/SKILL.md` makes the project discoverable by skill directories, but the useful functionality comes from the Codex plugin and MCP server.

## Features

- Discover local Pluto servers, preferring port `1234`.
- Attach to a visible Pluto notebook and update the same browser session.
- Open notebooks headlessly for isolated checks.
- List `@bind` variables and set bond values reactively.
- Read compact notebook state, including cells, output summaries, errors, logs, and current bond values.
- Export rendered notebooks to HTML.

## Requirements

- Codex with plugin and MCP support.
- Julia `1.11`.
- Node.js `20` or newer.
- `uv` for the Python-based test runner.

The plugin owns a Julia environment with `Pluto`, `HTTP`, and `JSON3`, so notebooks do not need to add Pluto just to be automated.

## Install From A Local Checkout

Clone the repository and install the Julia project once:

```bash
git clone https://github.com/EzraCerpac/PlutoPair.git
cd PlutoPair
julia --startup-file=no --project=. -e 'using Pkg; Pkg.instantiate()'
```

The bundled `.agents/plugins/marketplace.json` points at this repository root as the plugin directory. The plugin manifest is `.codex-plugin/plugin.json`, and the MCP server config is `.mcp.json`.

For ad hoc development, the MCP server can also be started directly:

```bash
node scripts/mcp_server.mjs
```

Set `PLUTO_NOTEBOOKS_PLUGIN_ROOT=/path/to/PlutoPair` only if you need to override root discovery.

## Skill Directories

Skill directories can import the repository or the direct `skills/SKILL.md` URL. The skill tells agents how to use the MCP tools; installing only the skill does not install the MCP server.

## Live Pairing Workflow

Start or reuse a trusted local Pluto server. Port `1234` is the default:

```julia
using Pluto
Pluto.run(port=1234)
```

Then ask Codex to use Pluto Pair. The normal flow is:

1. `pluto_discover_servers` checks for Pluto servers and visible notebooks.
2. `pluto_attach_session` attaches to a running notebook, or `pluto_open_visible` opens a notebook in that server.
3. `pluto_list_bonds` shows available `@bind` controls.
4. `pluto_set_bonds` changes a control and waits for reactivity.
5. `pluto_read_state` checks updated outputs.
6. `pluto_close_notebook` detaches from live sessions without closing the user's notebook.

Live pairing updates the same notebook the user sees in the browser.

## Headless Workflow

Use headless mode for CI-like checks, exports, and isolated notebook execution:

1. `pluto_list_notebooks` finds notebook files below a root.
2. `pluto_open_notebook` opens a notebook in a plugin-owned Pluto session.
3. `pluto_list_bonds`, `pluto_set_bonds`, and `pluto_read_state` inspect and drive it.
4. `pluto_export_html` writes a rendered HTML export.
5. `pluto_close_notebook` releases the session.

`execution_allowed` defaults to `true`. Pass `execution_allowed=false` for untrusted static preview.

## Limitations

- Pluto Pair changes `@bind` values and reads notebook state. It does not execute arbitrary Julia code inside an existing live notebook kernel.
- Ordinary Julia variables are out of scope unless a notebook exposes them through output or `@bind`.
- Live attach targets local trusted Pluto servers.
- Authenticated Pluto servers may require a `secret`.

## Development

Run the same checks used by CI:

```bash
node --check scripts/mcp_server.mjs
julia --startup-file=no --project=. -e 'include("scripts/pluto_worker.jl")' </dev/null
uv run python scripts/test_plugin.py
```

The test suite covers manifest parsing, MCP tool listing, headless notebook execution, live Pluto server attach, bond updates, state reads, exports, and live detach behavior.
