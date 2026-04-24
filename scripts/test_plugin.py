#!/usr/bin/env python3
import json
import os
import pathlib
import socket
import subprocess
import sys
import tempfile
import time

ROOT = pathlib.Path(__file__).resolve().parents[1]


def load_json(path):
    with open(path) as handle:
        return json.load(handle)


def call(proc, method, params=None, timeout=120):
    payload = {"id": call.next_id, "method": method, "params": params or {}}
    call.next_id += 1
    proc.stdin.write(json.dumps(payload) + "\n")
    proc.stdin.flush()
    deadline = time.time() + timeout
    while time.time() < deadline:
        line = proc.stdout.readline()
        if not line:
            raise RuntimeError("worker exited before response")
        response = json.loads(line)
        if response["id"] == payload["id"]:
            if not response["ok"]:
                raise RuntimeError(response["error"])
            return response["result"]
    raise TimeoutError(method)


call.next_id = 1


def write_tiny_notebook(path):
    path.write_text(
        """### A Pluto.jl notebook ###
# v0.20.26

using Markdown
using InteractiveUtils

# ╔═╡ cfc44218-b783-42a8-9e20-24786b3591f3
@bind x html"<input type=range min=1 max=10 value=3>"

# ╔═╡ df6951f5-759f-4fcc-8cd1-866fb4678b99
x * 2

# ╔═╡ Cell order:
# ╠═cfc44218-b783-42a8-9e20-24786b3591f3
# ╠═df6951f5-759f-4fcc-8cd1-866fb4678b99
""",
        encoding="utf-8",
    )


def free_port():
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def wait_for_ping(port, timeout=60):
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            import urllib.request

            with urllib.request.urlopen(f"http://127.0.0.1:{port}/ping", timeout=2) as response:
                if response.status == 200:
                    return
        except Exception:
            time.sleep(0.5)
    raise TimeoutError(f"Pluto server on port {port} did not start")


def test_live_server(tmp_path, notebook):
    port = free_port()
    server = subprocess.Popen(
        [
            "julia",
            "--startup-file=no",
            f"--project={ROOT}",
            "-e",
            f"using Pluto; Pluto.run(port={port}, host=\"127.0.0.1\", launch_browser=false, require_secret_for_access=false, require_secret_for_open_links=false)",
        ],
        cwd=ROOT,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        env={**os.environ, "JULIA_PROJECT": str(ROOT)},
    )
    worker = None
    try:
        wait_for_ping(port)
        worker = subprocess.Popen(
            ["julia", "--startup-file=no", f"--project={ROOT}", str(ROOT / "scripts" / "pluto_worker.jl")],
            cwd=ROOT,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env={**os.environ, "JULIA_PROJECT": str(ROOT)},
        )
        discovered = call(worker, "pluto_discover_servers", {"ports": [port]}, timeout=60)
        assert discovered["servers"], discovered
        assert discovered["servers"][0]["authenticated"] is True

        opened = call(worker, "pluto_open_visible", {"path": str(notebook), "port": port}, timeout=180)
        assert opened["kind"] == "attached"
        assert opened["remote_notebook_id"] in opened["browser_url"]

        notebook_id = opened["notebook_id"]
        bonds = call(worker, "pluto_list_bonds", {"notebook_id": notebook_id}, timeout=60)
        assert "x" in bonds["bond_names"]

        updated = call(worker, "pluto_set_bonds", {"notebook_id": notebook_id, "values": {"x": 8}}, timeout=120)
        assert updated["state"]["kind"] == "attached"
        assert updated["state"]["bonds"]["x"] == 8
        bodies = [str(cell.get("output", {}).get("body", "")) for cell in updated["state"]["cells"]]
        assert any("16" in body for body in bodies), bodies

        exported = call(worker, "pluto_export_html", {"notebook_id": notebook_id, "output_path": str(tmp_path / "live.html")}, timeout=120)
        assert pathlib.Path(exported["output_path"]).exists()
        assert exported["bytes"] > 0

        closed = call(worker, "pluto_close_notebook", {"notebook_id": notebook_id}, timeout=60)
        assert closed["detached_only"] is True
    finally:
        if worker is not None:
            worker.terminate()
            try:
                worker.wait(timeout=10)
            except subprocess.TimeoutExpired:
                worker.kill()
        server.terminate()
        try:
            server.wait(timeout=10)
        except subprocess.TimeoutExpired:
            server.kill()


def main():
    plugin_json = load_json(ROOT / ".codex-plugin" / "plugin.json")
    assert plugin_json["name"] == "pluto-pair"
    assert plugin_json["mcpServers"] == "./.mcp.json"
    load_json(ROOT / ".mcp.json")
    load_json(ROOT / ".agents" / "plugins" / "marketplace.json")

    with tempfile.TemporaryDirectory() as tmp:
        tmp_path = pathlib.Path(tmp)
        notebook = tmp_path / "tiny.jl"
        write_tiny_notebook(notebook)
        worker = subprocess.Popen(
            ["julia", "--startup-file=no", f"--project={ROOT}", str(ROOT / "scripts" / "pluto_worker.jl")],
            cwd=ROOT,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env={**os.environ, "JULIA_PROJECT": str(ROOT)},
        )
        try:
            listed = call(worker, "pluto_list_notebooks", {"root": str(tmp_path)})
            assert listed["notebooks"][0]["path"] == str(notebook)
            assert listed["notebooks"][0]["bonds"] == ["x"]

            opened = call(worker, "pluto_open_notebook", {"path": str(notebook), "execution_allowed": True}, timeout=180)
            notebook_id = opened["notebook_id"]
            bonds = call(worker, "pluto_list_bonds", {"notebook_id": notebook_id}, timeout=60)
            assert "x" in bonds["bond_names"]

            updated = call(worker, "pluto_set_bonds", {"notebook_id": notebook_id, "values": {"x": 7}}, timeout=120)
            assert updated["state"]["bonds"]["x"] == 7
            bodies = [str(cell.get("output", {}).get("body", "")) for cell in updated["state"]["cells"]]
            assert any("14" in body for body in bodies), bodies

            state = call(worker, "pluto_read_state", {"notebook_id": notebook_id, "include_outputs": True}, timeout=60)
            assert state["cell_count"] == 2

            html_path = tmp_path / "tiny.html"
            exported = call(worker, "pluto_export_html", {"notebook_id": notebook_id, "output_path": str(html_path)}, timeout=120)
            assert pathlib.Path(exported["output_path"]).exists()
            assert exported["bytes"] > 0

            closed = call(worker, "pluto_close_notebook", {"notebook_id": notebook_id})
            assert closed["closed"] is True
        finally:
            worker.terminate()
            try:
                worker.wait(timeout=10)
            except subprocess.TimeoutExpired:
                worker.kill()
            stderr = worker.stderr.read()
            if worker.returncode not in (0, -15, 143, None):
                print(stderr, file=sys.stderr)
                raise SystemExit(worker.returncode)

        test_live_server(tmp_path, notebook)

    server = subprocess.Popen(
        ["node", str(ROOT / "scripts" / "mcp_server.mjs")],
        cwd=ROOT,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        env={**os.environ, "PLUTO_NOTEBOOKS_PLUGIN_ROOT": str(ROOT)},
    )
    try:
        server.stdin.write(json.dumps({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}}) + "\n")
        server.stdin.flush()
        init = json.loads(server.stdout.readline())
        assert init["result"]["serverInfo"]["name"] == "pluto-pair"
        server.stdin.write(json.dumps({"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}}) + "\n")
        server.stdin.flush()
        tools = json.loads(server.stdout.readline())
        assert {tool["name"] for tool in tools["result"]["tools"]} >= {
            "pluto_open_notebook",
            "pluto_set_bonds",
            "pluto_discover_servers",
            "pluto_attach_session",
            "pluto_open_visible",
        }
    finally:
        server.terminate()
        try:
            server.wait(timeout=10)
        except subprocess.TimeoutExpired:
            server.kill()

    print("pluto-pair plugin tests passed")


if __name__ == "__main__":
    main()
