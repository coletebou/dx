#!/usr/bin/env node
// Runs one MCP stdio server and copies every byte it sends and receives to two
// files. The session stream only carries tool names, calls and results; this
// captures the rest of what the model is shown: the initialize instructions,
// tool descriptions and input schemas. Bytes are forwarded unchanged.
//   node mcp-tap.mjs <sent-file> <received-file> <command> [args...]
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';

const [sentFile, receivedFile, command, ...args] = process.argv.slice(2);
// Absolute paths only: a missing one must not turn into a file named "undefined".
if (!command || ![sentFile, receivedFile].every((f) => f && path.isAbsolute(f))) {
  console.error('usage: mcp-tap.mjs <absolute sent-file> <absolute received-file> <command> [args...]');
  process.exit(2);
}
const sent = fs.openSync(sentFile, 'a', 0o600);
const received = fs.openSync(receivedFile, 'a', 0o600);
// Written synchronously, before forwarding: whatever the other side saw is on
// disk even if the CLI SIGKILLs this tap at session end, which it does.
const record = (fd, buf) => {
  for (let off = 0; off < buf.length; ) off += fs.writeSync(fd, buf, off);
};
// Node on macOS adds __CF_USER_TEXT_ENCODING to its own environment at start;
// the server gets exactly the environment `env -i` gave this tap.
const { __CF_USER_TEXT_ENCODING, ...env } = process.env;
const server = spawn(command, args, { stdio: ['pipe', 'pipe', 'inherit'], env });

// Either side may vanish first; a broken pipe is not an error here.
for (const s of [server.stdin, process.stdout]) s.on('error', () => {});
process.stdin.on('data', (d) => {
  record(received, d);
  server.stdin.write(d);
});
process.stdin.on('end', () => server.stdin.end());
server.stdout.on('data', (d) => {
  record(sent, d);
  process.stdout.write(d);
});
server.on('error', (e) => {
  console.error(`mcp-tap: ${command}: ${e.message}`);
  process.exit(127);
});
// Exit only once stdout has flushed: process.exit() would discard forwarded
// bytes still queued for a CLI that is slow to read. The cap covers a CLI that
// has gone away, where the flush never completes.
server.on('close', (code, signal) => {
  process.exitCode = code ?? (signal ? 1 : 0);
  const exit = () => process.exit();
  process.stdout.end(exit);
  setTimeout(exit, 2000).unref();
});
for (const sig of ['SIGTERM', 'SIGINT', 'SIGHUP']) process.on(sig, () => server.kill(sig));
