#!/usr/bin/env node
// A wedged MCP server: it answers initialize and tools/list, then ignores both
// stdin EOF and SIGTERM. Only SIGKILL to the session's process group ends it.
import readline from 'node:readline';

process.on('SIGTERM', () => {});
setInterval(() => {}, 1000);
const out = (msg) => process.stdout.write(`${JSON.stringify({ jsonrpc: '2.0', ...msg })}\n`);
readline.createInterface({ input: process.stdin }).on('line', (line) => {
  const msg = JSON.parse(line);
  if (msg.method === 'initialize') out({ id: msg.id, result: { protocolVersion: '2025-06-18', capabilities: { tools: {} }, serverInfo: { name: 'stubborn', version: '0' } } });
  if (msg.method === 'tools/list') out({ id: msg.id, result: { tools: [] } });
});
