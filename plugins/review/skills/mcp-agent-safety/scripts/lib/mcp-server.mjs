// Minimal MCP server over stdio (newline-delimited JSON-RPC 2.0): initialize,
// ping, tools/list, tools/call. Zero dependencies, for toy servers and test
// doubles in suites. Handlers return any JSON value; it reaches the model as text.
// With `logFile`, every call and result is appended as JSONL: server-side
// ground truth for expectations, and an artifact for the canary sweep.
import fs from 'node:fs';
import readline from 'node:readline';

export function serveMcp({ name, version = '0.1.0', instructions, tools, logFile }) {
  const out = (msg) => process.stdout.write(`${JSON.stringify({ jsonrpc: '2.0', ...msg })}\n`);
  const log = (entry) => logFile && fs.appendFileSync(logFile, `${JSON.stringify({ at: new Date().toISOString(), server: name, ...entry })}\n`);
  const reply = (id, text, isError) => out({ id, result: { content: [{ type: 'text', text }], isError } });

  const rl = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
  rl.on('close', () => process.exit(0));
  rl.on('line', async (line) => {
    let msg;
    try {
      msg = JSON.parse(line);
    } catch {
      return;
    }
    if (msg.id == null) return; // notifications get no reply
    switch (msg.method) {
      case 'initialize':
        return out({ id: msg.id, result: { protocolVersion: msg.params?.protocolVersion ?? '2025-06-18', capabilities: { tools: {} }, serverInfo: { name, version }, instructions } });
      case 'ping':
        return out({ id: msg.id, result: {} });
      case 'tools/list':
        return out({ id: msg.id, result: { tools: tools.map(({ handler, ...t }) => t) } });
      case 'tools/call': {
        const tool = tools.find((t) => t.name === msg.params?.name);
        if (!tool) return out({ id: msg.id, error: { code: -32602, message: `unknown tool ${msg.params?.name}` } });
        const args = msg.params.arguments ?? {};
        try {
          const result = await tool.handler(args);
          log({ tool: tool.name, arguments: args, result });
          return reply(msg.id, JSON.stringify(result, null, 2), false);
        } catch (e) {
          log({ tool: tool.name, arguments: args, error: e.message });
          return reply(msg.id, `error: ${e.message}`, true);
        }
      }
      default:
        return out({ id: msg.id, error: { code: -32601, message: `method not found: ${msg.method}` } });
    }
  });
}
