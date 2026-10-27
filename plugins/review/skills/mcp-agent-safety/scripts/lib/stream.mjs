// Reads a `claude -p --output-format stream-json --verbose` session: what the
// model said, which tools it called and what came back, and the final result.
// Incremental, so hooks can watch the chat while the session is still running.

const tryJson = (text) => {
  try {
    return JSON.parse(text);
  } catch {
    return undefined;
  }
};

// mcp__<server>__<tool>; anything else is a built-in tool.
export function splitToolName(name) {
  const m = /^mcp__(.+?)__(.+)$/.exec(String(name ?? ''));
  return m ? { server: m[1], tool: m[2] } : { server: null, tool: name };
}

function resultText(content) {
  if (typeof content === 'string') return content;
  if (Array.isArray(content)) return content.map((c) => (c?.type === 'text' ? c.text : `[${c?.type}]`)).join('\n');
  return JSON.stringify(content ?? '');
}

export function createSessionParser() {
  const session = { init: null, chat: '', toolCalls: [], result: null, events: 0 };
  const byId = new Map();
  return {
    session,
    push(line) {
      if (!line.trim()) return;
      const ev = tryJson(line);
      if (!ev || typeof ev !== 'object') return;
      session.events++;
      if (ev.type === 'system' && ev.subtype === 'init') session.init = ev;
      else if (ev.type === 'result') session.result = ev;
      else if (ev.type === 'assistant') {
        for (const block of ev.message?.content ?? []) {
          if (block.type === 'text') session.chat += `\n${block.text}`;
          if (block.type !== 'tool_use') continue;
          const call = { id: block.id, name: block.name, ...splitToolName(block.name), input: block.input ?? {}, output: null, json: undefined, isError: null };
          byId.set(block.id, call);
          session.toolCalls.push(call);
        }
      } else if (ev.type === 'user' && Array.isArray(ev.message?.content)) {
        for (const block of ev.message.content) {
          const call = block.type === 'tool_result' ? byId.get(block.tool_use_id) : null;
          if (!call) continue;
          call.output = resultText(block.content);
          call.json = tryJson(call.output);
          call.isError = Boolean(block.is_error);
        }
      }
    },
  };
}

export function parseStream(text) {
  const parser = createSessionParser();
  for (const line of String(text).split('\n')) parser.push(line);
  return parser.session;
}
