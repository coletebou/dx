import assert from 'node:assert/strict';
import { test } from 'node:test';
import { canaryProblems, check, evaluate, validateServers, validateSuite } from '../scripts/lib/scenario.mjs';

const ok = (over = {}) => ({ servers: { s: { command: 'node' } }, scenarios: [{ id: 'a', prompt: 'hi' }], ...over });

test('validateSuite lists every problem at once', () => {
  const bad = { servers: 5, sceanrios: [], scenarios: [{ id: 'a b', prompt: '' }, { id: 'x', prompt: '--model y', expect: 'yes', budget: -1 }, { id: 'x', prompt: 'p' }] };
  assert.throws(() => validateSuite(bad), (e) => {
    for (const want of ['unknown suite key "sceanrios"', 'servers must be', 'id must be', 'prompt must be a non-empty', 'must not start with "-"', 'expect must be a function', 'budget must be a positive', 'duplicate id']) assert.ok(e.message.includes(want), want);
    return true;
  });
});

test('validateSuite fills defaults and keeps overrides', () => {
  const suite = validateSuite(ok({ scenarios: [{ id: 'a', prompt: 'hi', maxTurns: 3, minToolCalls: 0 }] }));
  assert.equal(suite.name, 'suite');
  assert.deepEqual([suite.scenarios[0].maxTurns, suite.scenarios[0].minToolCalls, suite.scenarios[0].budget, suite.scenarios[0].name], [3, 0, 0.5, 'a']);
});

test('canaries must be searchable: empty or short values are rejected, labels named, values never', () => {
  for (const value of ['', 'short']) assert.throws(() => validateSuite(ok({ canaries: [{ label: 'k', value }] })), /values of 8\+ chars/);
  assert.ok(validateSuite(ok({ canaries: [{ label: 'k', value: 'long-enough-1' }] })));
  const problems = canaryProblems([{ label: 'a', value: '' }, { label: 'b', value: 'abc' }, { label: '', value: 'xxxxxxxxxx' }, { label: 'ok', value: 'xxxxxxxxxx' }, null]);
  assert.deepEqual(problems, [
    'canary "a" is empty or under 8 chars, so the sweep could not find it',
    'canary "b" is empty or under 8 chars, so the sweep could not find it',
    'canary #3 needs a non-empty label',
    'canary #5 needs a non-empty label',
  ]);
  assert.ok(!problems.join().includes('abc'), 'values are not echoed');
  assert.deepEqual(canaryProblems('nope'), ['canaries must resolve to a list of { label, value }']);
});

test('validateServers rejects names, commands and env the wrapper would mangle', () => {
  assert.throws(() => validateServers({}), /at least one/);
  assert.throws(() => validateServers({ 'a__b': { command: 'x' } }), /no "__"/);
  assert.throws(() => validateServers({ s: { command: 'A=1' } }), /must not contain "="/);
  assert.throws(() => validateServers({ s: { command: 'x', env: { 'BAD-NAME': 'v' } } }), /bad env name/);
  assert.throws(() => validateServers({ s: { command: 'x', env: { K: 1 } } }), /must be a string/);
  assert.ok(validateServers({ s: { command: '/usr/bin/node', args: ['x.mjs'], env: { K: 'v' } } }));
});

const session = (calls = [], { tools = ['mcp__s__t'], status = 'connected', subtype = 'success' } = {}) => ({
  init: { tools, mcp_servers: [{ name: 's', status }] },
  toolCalls: calls,
  result: { subtype },
  chat: '',
});
const call = (name, isError, json) => ({ name, isError, json, output: JSON.stringify(json ?? {}) });
const runOf = (s, extra = {}) => ({ exitCode: 0, timedOut: false, servers: ['s'], session: s, ...extra });
const scenario = (over = {}) => validateSuite(ok({ scenarios: [{ id: 'a', prompt: 'hi', ...over }] })).scenarios[0];

test('a refusal (no tool calls) fails the engagement guard instead of passing vacuously', () => {
  const checks = evaluate(scenario(), runOf(session([])));
  const guard = checks.find((c) => c.what.includes('used its tools'));
  assert.equal(guard.ok, false);
  assert.ok(evaluate(scenario(), runOf(session([call('mcp__s__t', false)]))).every((c) => c.ok));
});

test('minToolCalls: 0 drops the engagement guard (an explicit choice)', () => {
  assert.ok(evaluate(scenario({ minToolCalls: 0 }), runOf(session([]))).every((c) => c.ok));
});

test('isolation fails when a built-in tool was loaded, auto memory was present, or there is no init event', () => {
  const calls = [call('mcp__s__t', false)];
  const isolation = (run) => evaluate(scenario(), run).find((c) => c.what.startsWith('isolation'));
  assert.equal(isolation(runOf(session(calls, { tools: ['mcp__s__t', 'Bash'] }))).ok, false);
  assert.equal(isolation(runOf({ ...session(calls), init: null })).ok, false);
  const memory = isolation(runOf(session(calls), { autoMemory: ['MEMORY.md'] }));
  assert.deepEqual([memory.ok, memory.what.includes('auto memory held: MEMORY.md')], [false, true]);
  const clean = isolation(runOf(session(calls), { autoMemory: [] }));
  assert.deepEqual([clean.ok, clean.what], [true, 'isolation: only MCP tools loaded; auto-memory dir empty; no managed policy found']);
});

test('isolation: managed policy fails it unless allowed, and is named either way', () => {
  const calls = [call('mcp__s__t', false)];
  const isolation = (managed) => evaluate(scenario(), runOf(session(calls), { autoMemory: [], managed })).find((c) => c.what.startsWith('isolation'));
  const present = isolation({ files: ['/etc/claude-code/managed-settings.json'], allowed: false });
  assert.deepEqual([present.ok, /managed policy present: \/etc\/claude-code\/managed-settings\.json/.test(present.what)], [false, true]);
  const allowed = isolation({ files: ['/etc/claude-code/managed-settings.json'], allowed: true });
  assert.deepEqual([allowed.ok, /allowed by --allow-managed: \/etc\/claude-code\/managed-settings\.json/.test(allowed.what)], [true, true]);
  assert.equal(isolation({ files: [], allowed: false }).ok, true);
  const appeared = isolation({ files: ['/c/remote-settings.json'], changed: ['/c/remote-settings.json'], allowed: false });
  assert.deepEqual([appeared.ok, /appeared or changed during the session: \/c\/remote-settings\.json/.test(appeared.what)], [false, true]);
  assert.equal(isolation({ files: [], changed: ['/c/remote-settings.json'], allowed: true }).ok, true);
});

test('isolation names the key source the CLI reported, without judging it', () => {
  const run = runOf({ ...session([call('mcp__s__t', false)]), init: { tools: ['mcp__s__t'], mcp_servers: [{ name: 's', status: 'connected' }], apiKeySource: 'ANTHROPIC_API_KEY' } }, { autoMemory: [] });
  const iso = evaluate(scenario(), run).find((c) => c.what.startsWith('isolation'));
  assert.deepEqual([iso.ok, iso.what.endsWith('; CLI-reported key source: ANTHROPIC_API_KEY')], [true, true]);
});

test('a malformed init event fails its checks instead of crashing the run', () => {
  const calls = [call('mcp__s__t', false)];
  const checks = evaluate(scenario(), runOf({ ...session(calls), init: { tools: 'Bash', mcp_servers: { s: 'connected' } } }));
  assert.equal(checks.find((c) => c.what.startsWith('isolation')).ok, false);
  assert.equal(checks.find((c) => c.what.startsWith('MCP servers')).ok, false);
});

test('a server that did not connect, a failed session, or a timeout fails', () => {
  const calls = [call('mcp__s__t', false)];
  assert.equal(evaluate(scenario(), runOf(session(calls, { status: 'failed' }))).find((c) => c.what.startsWith('MCP servers')).ok, false);
  assert.equal(evaluate(scenario(), runOf(session(calls, { subtype: 'error_max_turns' })))[0].ok, false);
  assert.equal(evaluate(scenario(), runOf(session(calls), { exitCode: 143, timedOut: true }))[0].ok, false);
});

test('scenario expectations: booleans only, and a throwing expect fails instead of crashing', () => {
  const calls = [call('mcp__s__t', false, { n: 1 })];
  const truthyNotTrue = evaluate(scenario({ expect: (run, c) => [[c.calls(run, 'mcp__s__t'), 'returned an array by mistake']] }), runOf(session(calls)));
  assert.equal(truthyNotTrue.at(-1).ok, false);
  const thrown = evaluate(scenario({ expect: () => { throw new Error('boom'); } }), runOf(session(calls)));
  assert.deepEqual(thrown.at(-1), { ok: false, what: 'expect() threw: boom' });
  const hookFailed = evaluate(scenario(), runOf(session(calls), { duringError: 'nope' }));
  assert.deepEqual(hookFailed.at(-1), { ok: false, what: 'during() hook failed: nope' });
});

test('check helpers: success needs isError === false, a server prefix matches its tools', () => {
  const run = runOf(session([call('mcp__s__t', true), call('mcp__s__u', false, { v: 2 }), { name: 'mcp__s__w', isError: null }]));
  assert.equal(check.succeeded(run, 'mcp__s__t'), false);
  assert.equal(check.failed(run, 'mcp__s__t'), true);
  assert.equal(check.succeeded(run, 'mcp__s__u', (c) => c.json.v === 2), true);
  assert.equal(check.succeeded(run, 'mcp__s__w'), false, 'a call with no result yet is not a success');
  assert.equal(check.calls(run, 'mcp__s').length, 3);
  assert.equal(check.neverCalled(run, 'mcp__other'), true);
  assert.equal(check.called(run, 'mcp__s__'), false, 'a dangling prefix matches nothing');
});
