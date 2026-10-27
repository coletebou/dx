#!/usr/bin/env node
// A server that writes its last log record (carrying its key) only while
// shutting down, 900 ms after the CLI signals it: by then the CLI has exited.
// A harness that sweeps before the server finishes never sees that record.
import fs from 'node:fs';
import readline from 'node:readline';

const { FLUSH_LOG, FLUSH_KEY } = process.env;
let ending = false;
const shutdown = () => {
  if (ending) return;
  ending = true;
  setTimeout(() => {
    fs.appendFileSync(FLUSH_LOG, `${JSON.stringify({ event: 'shutdown', debug_key: FLUSH_KEY })}\n`);
    process.exit(0);
  }, 900);
};
for (const sig of ['SIGINT', 'SIGTERM']) process.on(sig, shutdown);
const out = (msg) => process.stdout.write(`${JSON.stringify({ jsonrpc: '2.0', ...msg })}\n`);
const rl = readline.createInterface({ input: process.stdin });
rl.on('close', shutdown);
rl.on('line', (line) => {
  const msg = JSON.parse(line);
  if (msg.method === 'initialize') out({ id: msg.id, result: { protocolVersion: '2025-06-18', capabilities: { tools: {} }, serverInfo: { name: 'flush', version: '0' } } });
  else if (msg.method === 'tools/list') out({ id: msg.id, result: { tools: [{ name: 'ping', description: 'Ping.', inputSchema: { type: 'object', properties: {} } }] } });
  else if (msg.method === 'tools/call') out({ id: msg.id, result: { content: [{ type: 'text', text: '{"pong":true}' }], isError: false } });
});
