import assert from 'node:assert/strict';
import { test } from 'node:test';
import { parseStream, splitToolName } from '../scripts/lib/stream.mjs';

const STREAM = [
  { type: 'system', subtype: 'init', tools: ['mcp__billing__get_balance'], mcp_servers: [{ name: 'billing', status: 'connected' }] },
  { type: 'assistant', message: { content: [{ type: 'text', text: 'Let me check.' }, { type: 'tool_use', id: 't1', name: 'mcp__billing__get_balance', input: { account: 'acct_demo' } }] } },
  { type: 'user', message: { content: [{ type: 'tool_result', tool_use_id: 't1', content: [{ type: 'text', text: '{"balance_cents":123456}' }], is_error: false }] } },
  { type: 'assistant', message: { content: [{ type: 'tool_use', id: 't2', name: 'Bash', input: { command: 'ls' } }] } },
  { type: 'user', message: { content: [{ type: 'tool_result', tool_use_id: 't2', content: 'not allowed', is_error: true }] } },
  { type: 'user', message: { content: 'plain user text' } },
  { type: 'result', subtype: 'success', num_turns: 3, total_cost_usd: 0.01, result: 'It is $1,234.56.' },
]
  .map((e) => JSON.stringify(e))
  .join('\n');

test('parses chat, tool calls with their results, and the result event', () => {
  const s = parseStream(`${STREAM}\nnot json at all\n\n`);
  assert.equal(s.init.mcp_servers[0].status, 'connected');
  assert.equal(s.chat.trim(), 'Let me check.');
  assert.equal(s.toolCalls.length, 2);
  const [balance, bash] = s.toolCalls;
  assert.deepEqual([balance.server, balance.tool, balance.isError, balance.json], ['billing', 'get_balance', false, { balance_cents: 123456 }]);
  assert.deepEqual(balance.input, { account: 'acct_demo' });
  assert.deepEqual([bash.server, bash.tool, bash.isError, bash.output], [null, 'Bash', true, 'not allowed']);
  assert.equal(s.result.total_cost_usd, 0.01);
  assert.equal(s.events, 7);
});

test('a tool call with no result yet stays pending (isError null)', () => {
  const s = parseStream(STREAM.split('\n').slice(0, 2).join('\n'));
  assert.equal(s.toolCalls[0].isError, null);
  assert.equal(s.toolCalls[0].output, null);
});

test('splits MCP tool names, leaves built-ins alone', () => {
  assert.deepEqual(splitToolName('mcp__my-server__do_thing'), { server: 'my-server', tool: 'do_thing' });
  assert.deepEqual(splitToolName('WebFetch'), { server: null, tool: 'WebFetch' });
});
