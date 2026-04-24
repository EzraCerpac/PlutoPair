#!/usr/bin/env node
import { spawn } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import readline from "node:readline";
import { fileURLToPath } from "node:url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const pluginRoot = process.env.PLUTO_NOTEBOOKS_PLUGIN_ROOT || path.resolve(__dirname, "..");

const tools = [
  {
    name: "pluto_discover_servers",
    description: "Discover local Pluto servers and list visible notebooks when authenticated.",
    inputSchema: {
      type: "object",
      properties: {
        ports: {
          type: "array",
          items: { type: "integer" },
          default: [1234],
          description: "Ports to probe, preferring 1234 by default.",
        },
        host: { type: "string", default: "127.0.0.1" },
      },
    },
  },
  {
    name: "pluto_list_notebooks",
    description: "List Pluto.jl notebook files below a root directory.",
    inputSchema: {
      type: "object",
      properties: {
        root: { type: "string", description: "Directory to search." },
        globs: {
          type: "array",
          items: { type: "string" },
          description: "Optional simple glob suffixes, for example ['notebooks/*.jl'].",
        },
      },
      required: ["root"],
    },
  },
  {
    name: "pluto_open_notebook",
    description: "Open a Pluto.jl notebook in the Julia worker.",
    inputSchema: {
      type: "object",
      properties: {
        path: { type: "string" },
        project: { type: "string", description: "Optional Julia project path for context." },
        execution_allowed: { type: "boolean", default: true },
      },
      required: ["path"],
    },
  },
  {
    name: "pluto_attach_session",
    description: "Attach to a notebook already running in a local Pluto server.",
    inputSchema: {
      type: "object",
      properties: {
        url: { type: "string", description: "Base Pluto URL, for example http://127.0.0.1:1234." },
        port: { type: "integer", default: 1234 },
        host: { type: "string", default: "127.0.0.1" },
        secret: { type: "string", description: "Optional Pluto secret token." },
        notebook_id: { type: "string", description: "Notebook UUID to attach to." },
        path: { type: "string", description: "Notebook path to resolve on the server." },
      },
    },
  },
  {
    name: "pluto_open_visible",
    description: "Open a notebook in an existing visible Pluto server, attach to it, and return the browser URL.",
    inputSchema: {
      type: "object",
      properties: {
        path: { type: "string" },
        port: { type: "integer", default: 1234 },
        host: { type: "string", default: "127.0.0.1" },
        secret: { type: "string", description: "Optional Pluto secret token." },
        execution_allowed: { type: "boolean", default: true },
      },
      required: ["path"],
    },
  },
  {
    name: "pluto_list_bonds",
    description: "List @bind variable names for an opened notebook.",
    inputSchema: {
      type: "object",
      properties: { notebook_id: { type: "string" } },
      required: ["notebook_id"],
    },
  },
  {
    name: "pluto_set_bonds",
    description: "Set @bind values and trigger Pluto reactivity.",
    inputSchema: {
      type: "object",
      properties: {
        notebook_id: { type: "string" },
        values: { type: "object", additionalProperties: true },
        wait: { type: "boolean", default: true },
      },
      required: ["notebook_id", "values"],
    },
  },
  {
    name: "pluto_read_state",
    description: "Read compact notebook state, including code snippets, output summaries, errors, logs, and bonds.",
    inputSchema: {
      type: "object",
      properties: {
        notebook_id: { type: "string" },
        include_outputs: { type: "boolean", default: true },
      },
      required: ["notebook_id"],
    },
  },
  {
    name: "pluto_export_html",
    description: "Export an opened notebook to HTML.",
    inputSchema: {
      type: "object",
      properties: {
        notebook_id: { type: "string" },
        output_path: { type: "string" },
      },
      required: ["notebook_id"],
    },
  },
  {
    name: "pluto_close_notebook",
    description: "Close an opened notebook and release its Pluto session state.",
    inputSchema: {
      type: "object",
      properties: { notebook_id: { type: "string" } },
      required: ["notebook_id"],
    },
  },
];

let nextWorkerId = 1;
const pending = new Map();
let worker = null;
let workerLines = null;

function sendMessage(message) {
  process.stdout.write(`${JSON.stringify(message)}\n`);
}

function textContent(payload) {
  return [{ type: "text", text: JSON.stringify(payload, null, 2) }];
}

function startWorker() {
  if (worker) return worker;
  const script = path.join(pluginRoot, "scripts", "pluto_worker.jl");
  worker = spawn("julia", ["--startup-file=no", `--project=${pluginRoot}`, script], {
    cwd: pluginRoot,
    stdio: ["pipe", "pipe", "pipe"],
    env: { ...process.env, JULIA_PROJECT: pluginRoot },
  });

  workerLines = readline.createInterface({ input: worker.stdout });
  workerLines.on("line", (line) => {
    let response;
    try {
      response = JSON.parse(line);
    } catch (error) {
      process.stderr.write(`[pluto-worker invalid-json] ${line}\n`);
      return;
    }
    const entry = pending.get(response.id);
    if (!entry) return;
    pending.delete(response.id);
    if (response.ok) {
      entry.resolve(response.result);
    } else {
      entry.reject(new Error(response.error || "Julia worker failed"));
    }
  });

  worker.stderr.on("data", (chunk) => {
    process.stderr.write(`[pluto-worker] ${chunk}`);
  });

  worker.on("exit", (code, signal) => {
    worker = null;
    for (const [id, entry] of pending.entries()) {
      pending.delete(id);
      entry.reject(new Error(`Julia worker exited before response ${id} (code=${code}, signal=${signal})`));
    }
  });

  return worker;
}

function callWorker(method, params = {}) {
  startWorker();
  const id = nextWorkerId++;
  const payload = { id, method, params };
  return new Promise((resolve, reject) => {
    pending.set(id, { resolve, reject });
    worker.stdin.write(`${JSON.stringify(payload)}\n`, (error) => {
      if (error) {
        pending.delete(id);
        reject(error);
      }
    });
  });
}

function handleInitialize(id) {
  sendMessage({
    jsonrpc: "2.0",
    id,
    result: {
      protocolVersion: "2025-06-18",
      capabilities: { tools: {} },
      serverInfo: { name: "pluto-pair", version: "0.1.0" },
    },
  });
}

async function handleToolCall(id, params) {
  const name = params?.name;
  const args = params?.arguments || {};
  if (!tools.some((tool) => tool.name === name)) {
    throw new Error(`Unknown tool: ${name}`);
  }
  const result = await callWorker(name, args);
  sendMessage({ jsonrpc: "2.0", id, result: { content: textContent(result) } });
}

async function handleRequest(request) {
  const { id, method, params } = request;
  if (method === "initialize") {
    handleInitialize(id);
  } else if (method === "notifications/initialized") {
    return;
  } else if (method === "tools/list") {
    sendMessage({ jsonrpc: "2.0", id, result: { tools } });
  } else if (method === "tools/call") {
    await handleToolCall(id, params);
  } else if (id !== undefined) {
    sendMessage({ jsonrpc: "2.0", id, error: { code: -32601, message: `Method not found: ${method}` } });
  }
}

const input = readline.createInterface({ input: process.stdin });
input.on("line", async (line) => {
  if (!line.trim()) return;
  let request;
  try {
    request = JSON.parse(line);
  } catch (error) {
    sendMessage({ jsonrpc: "2.0", error: { code: -32700, message: error.message } });
    return;
  }
  try {
    await handleRequest(request);
  } catch (error) {
    sendMessage({
      jsonrpc: "2.0",
      id: request.id,
      error: { code: -32000, message: error.message, data: error.stack },
    });
  }
});

process.on("SIGINT", () => process.exit(130));
process.on("SIGTERM", () => process.exit(143));
