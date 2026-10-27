#!/usr/bin/env node
// Stand-in for `claude -p` in tests: no model, no network. It starts the first
// MCP server from --mcp-config exactly as Claude Code would (through the
// harness's env -i wrapper), calls FAKE_TOOL with FAKE_ARGS (JSON) if set, and
// prints the stream-json events a real session would.
//   FAKE_TOOL    tool to call once (unset: answer without tools, like a refusal)
//   FAKE_ARGS    its arguments as JSON
//   FAKE_ANSWER  the final answer text
//   FAKE_ARGV    file to write the received argv and cwd to (JSON)
//   FAKE_MEMORY_DIR  report this as the auto-memory dir in the init event
//   FAKE_MEMORY_ROOT create and report <root>/<sanitized cwd>/memory/, as the CLI does
//   FAKE_MEMORY_FILE  also put a (non-memory) file with this name in it
//   FAKE_HANG    never send a result; with FAKE_IGNORE_SIGTERM=1, ignore SIGTERM too
//   FAKE_TOUCH   write this file mid-session, as a server-managed policy fetch would
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import readline from 'node:readline';

const argv = process.argv.slice(2);
if (process.env.FAKE_ARGV) fs.writeFileSync(process.env.FAKE_ARGV, JSON.stringify({ argv, cwd: process.cwd() }));
if (process.env.FAKE_IGNORE_SIGTERM === '1') process.on('SIGTERM', () => {});
const config = JSON.parse(fs.readFileSync(argv[argv.indexOf('--mcp-config') + 1], 'utf8'));
const [serverName, spec] = Object.entries(config.mcpServers)[0];
const emit = (ev) => process.stdout.write(`${JSON.stringify(ev)}\n`);

// Like the real CLI, server stderr comes back to the CLI, not to our caller's stream.
const server = spawn(spec.command, spec.args, { stdio: ['pipe', 'pipe', 'pipe'] });
server.stderr.on('data', (d) => process.stderr.write(d));
const waiting = new Map();
let nextId = 0;
readline.createInterface({ input: server.stdout }).on('line', (line) => {
  const msg = JSON.parse(line);
  waiting.get(msg.id)?.(msg);
  waiting.delete(msg.id);
});
const request = (method, params) =>
  new Promise((resolve) => {
    const id = ++nextId;
    waiting.set(id, resolve);
    server.stdin.write(`${JSON.stringify({ jsonrpc: '2.0', id, method, params })}\n`);
  });

await request('initialize', { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'fake-claude', version: '0' } });
const { tools } = (await request('tools/list', {})).result;
// Like the real CLI, FAKE_MEMORY_ROOT gets a <sanitized cwd>/memory/ dir per session.
let memoryDir = process.env.FAKE_MEMORY_DIR;
if (process.env.FAKE_MEMORY_ROOT) {
  memoryDir = path.join(process.env.FAKE_MEMORY_ROOT, process.cwd().replace(/[^A-Za-z0-9]/g, '-'), 'memory');
  fs.mkdirSync(memoryDir, { recursive: true });
  if (process.env.FAKE_MEMORY_FILE) fs.writeFileSync(path.join(memoryDir, process.env.FAKE_MEMORY_FILE), 'not memory, but not ours to delete\n');
}
const memory = memoryDir ? { memory_paths: { auto: `${memoryDir}/` } } : {};
emit({ type: 'system', subtype: 'init', tools: tools.map((t) => `mcp__${serverName}__${t.name}`), mcp_servers: [{ name: serverName, status: 'connected' }], model: 'fake', ...memory });
if (process.env.FAKE_TOUCH) fs.writeFileSync(process.env.FAKE_TOUCH, '{"permissions":{}}');
if (process.env.FAKE_HANG === '1') {
  setInterval(() => {}, 1000); // a wedged session: alive, but no result, ever
  await new Promise(() => {});
}
let turns = 1;
if (process.env.FAKE_TOOL) {
  const input = JSON.parse(process.env.FAKE_ARGS ?? '{}');
  emit({ type: 'assistant', message: { content: [{ type: 'text', text: 'Checking.' }, { type: 'tool_use', id: 'toolu_1', name: `mcp__${serverName}__${process.env.FAKE_TOOL}`, input }] } });
  const { result } = await request('tools/call', { name: process.env.FAKE_TOOL, arguments: input });
  emit({ type: 'user', message: { content: [{ type: 'tool_result', tool_use_id: 'toolu_1', content: result.content, is_error: result.isError }] } });
  turns++;
}
const answer = process.env.FAKE_ANSWER ?? 'Done.';
emit({ type: 'assistant', message: { content: [{ type: 'text', text: answer }] } });
emit({ type: 'result', subtype: 'success', is_error: false, num_turns: turns, total_cost_usd: 0, result: answer });
// The real CLI's shutdown (2.1.302, observed): SIGINT to each server, SIGTERM
// 100 ms later, and exit about 450 ms after that, killing what is left without
// waiting for it to finish.
server.kill('SIGINT');
setTimeout(() => server.kill('SIGTERM'), 100);
setTimeout(() => {
  server.kill('SIGKILL');
  process.exit(0);
}, 550);
