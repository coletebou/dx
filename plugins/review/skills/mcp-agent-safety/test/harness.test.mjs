// The harness end to end, without a model: a fake `claude` that makes a real
// MCP round trip through the env -i wrapper and the tap to the example server.
import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import readline from 'node:readline';
import { after, test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { ambientConfig, claudeArgs, envCredentialHits, isolatedCwd, makeCanary, managedPolicySources, runSession, serverConfigProblems, wrapServer } from '../scripts/lib/claude.mjs';
import { findLeaks } from '../scripts/lib/leaks.mjs';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const TMP = path.join(ROOT, 'test', '.tmp');
const FAKE_CLAUDE = path.join(ROOT, 'test', 'fixtures', 'fake-claude.mjs');
const BILLING = path.join(ROOT, 'examples', 'billing-server.mjs');
const EDGE = 'test/fixtures/edge-cases.suites.mjs';
const TAP = path.join(ROOT, 'scripts', 'lib', 'mcp-tap.mjs');
fs.mkdirSync(TMP, { recursive: true });
const scratch = (tag) => fs.mkdtempSync(path.join(TMP, `${tag}-`));
after(() => fs.rmSync(TMP, { recursive: true, force: true }));
const tap = (dir) => ({ home: dir, sentFile: path.join(dir, 'sent.log'), receivedFile: path.join(dir, 'received.log') });

test('claudeArgs: the isolation flags, never --bare, prompt last, model only when given', () => {
  const args = claudeArgs({ mcpConfig: '/x/mcp.json', allowedTools: ['mcp__a', 'mcp__b'], maxTurns: 5, budget: 0.2, prompt: 'hello' });
  const value = (flag) => args[args.indexOf(flag) + 1];
  for (const flag of ['-p', '--strict-mcp-config', '--no-session-persistence', '--verbose']) assert.ok(args.includes(flag), flag);
  assert.deepEqual(
    ['--setting-sources', '--mcp-config', '--tools', '--allowedTools', '--max-turns', '--max-budget-usd', '--output-format'].map(value),
    ['', '/x/mcp.json', '', 'mcp__a,mcp__b', '5', '0.2', 'stream-json'],
  );
  assert.ok(!args.includes('--bare') && !args.includes('--model'));
  assert.equal(args.at(-1), 'hello');
  const withModel = claudeArgs({ mcpConfig: 'm', allowedTools: ['x'], maxTurns: 1, budget: 1, prompt: 'p', model: 'some-model', system: 'sys' });
  assert.equal(withModel[withModel.indexOf('--model') + 1], 'some-model');
  assert.equal(withModel[withModel.indexOf('--append-system-prompt') + 1], 'sys');
});

test('wrapServer: a server sees only PATH, HOME and its declared env, and the tap copies its bytes', () => {
  const dir = scratch('wrap');
  const w = wrapServer({ command: '/usr/bin/env', env: { DECLARED: 'yes' } }, tap(dir));
  const out = spawnSync(w.command, w.args, { encoding: 'utf8', env: { ...process.env, CALLER_SECRET_TOKEN: 'must-not-reach-the-server' } }).stdout;
  assert.deepEqual(out.trim().split('\n').map((l) => l.split('=')[0]).sort(), ['DECLARED', 'HOME', 'PATH']);
  assert.ok(out.includes(`HOME=${dir}\n`));
  assert.ok(!out.includes('must-not-reach'));
  assert.equal(fs.readFileSync(path.join(dir, 'sent.log'), 'utf8'), out, 'the tap recorded exactly what the server sent');
});

test('a missing tap path is an error, never a file named "undefined"', () => {
  assert.throws(() => wrapServer({ command: 'node' }, { home: '/h' }), /sentFile must be an absolute path/);
  assert.throws(() => wrapServer({ command: 'node' }, { home: '/h', sentFile: 'rel.log', receivedFile: '/r.log' }), /sentFile must be an absolute path/);
  const dir = scratch('tapargs');
  const r = spawnSync(process.execPath, [path.join(ROOT, 'scripts', 'lib', 'mcp-tap.mjs'), 'undefined', 'undefined', '/usr/bin/true'], { cwd: dir, encoding: 'utf8' });
  assert.equal(r.status, 2);
  assert.deepEqual(fs.readdirSync(dir), [], 'the tap wrote nothing');
});

test('envCredentialHits finds credential values in any swept encoding, names only', () => {
  const env = { API_TOKEN: 'abcdefghijklmnop', SHORT_KEY: 'abc', PLAIN_VALUE: 'qrstuvwxyz012345', DB_PASSWORD: 'zzzzzzzzzzzzzzzz' };
  assert.deepEqual(envCredentialHits('x abcdefghijklmnop abc qrstuvwxyz012345 y', env), ['API_TOKEN']);
  const basic = `Authorization: Basic ${Buffer.from('user:abcdefghijklmnop').toString('base64')}`;
  assert.deepEqual(envCredentialHits(basic, env), ['API_TOKEN'], 'base64 inside HTTP Basic');
});

test('serverConfigProblems: refuses ${VAR} for Claude Code to expand, and decoded real credentials', () => {
  const env = { HARNESS_TEST_TOKEN: 'line-one-0123456789\nline-two-abcdefghij' };
  const wrapped = (extra) => ({ s: wrapServer({ command: 'node', args: ['s.mjs'], env: extra }, tap('/t')) });
  assert.deepEqual(serverConfigProblems(wrapped({ K: 'sk_test_FAKE_fine_0123' }), env), []);
  assert.match(serverConfigProblems(wrapped({ K: '${HARNESS_TEST_TOKEN}' }), env)[0], /would be expanded by Claude Code/);
  assert.match(serverConfigProblems(wrapped({ K: env.HARNESS_TEST_TOKEN }), env)[0], /HARNESS_TEST_TOKEN/, 'a multiline value is found decoded');
});

test('isolatedCwd: a fresh empty dir with no project context above it; refused under one', () => {
  const dir = isolatedCwd();
  try {
    assert.ok(dir.startsWith(fs.realpathSync(os.tmpdir())));
    assert.deepEqual(fs.readdirSync(dir), []);
    assert.deepEqual(ambientConfig(dir), []);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
  const root = scratch('ctx');
  fs.writeFileSync(path.join(root, 'CLAUDE.md'), 'instructions\n');
  assert.throws(() => isolatedCwd(root), /sits under project context \(.*CLAUDE\.md/);
  assert.deepEqual(fs.readdirSync(root), ['CLAUDE.md'], 'the refused dir was removed');
});

test('managedPolicySources finds every documented organization policy source, and nothing on a clean host', () => {
  const root = scratch('policy');
  assert.deepEqual(managedPolicySources({ platform: 'darwin', root, configDir: '/home/u/.claude', user: 'u' }), []);
  const mac = ['/Library/Application Support/ClaudeCode/managed-settings.json', '/Library/Application Support/ClaudeCode/managed-settings.d', '/Library/Application Support/ClaudeCode/managed-mcp.json', '/Library/Application Support/ClaudeCode/CLAUDE.md', '/Library/Managed Preferences/u/com.anthropic.claudecode.plist', '/Library/Managed Preferences/com.anthropic.claudecode.plist', '/home/u/.claude/remote-settings.json'];
  const linux = ['/etc/claude-code/managed-settings.json', '/etc/claude-code/managed-settings.d', '/etc/claude-code/managed-mcp.json', '/etc/claude-code/CLAUDE.md', '/mnt/c/Program Files/ClaudeCode/managed-settings.json'];
  for (const f of [...mac, ...linux]) {
    fs.mkdirSync(path.dirname(path.join(root, f)), { recursive: true });
    if (f.endsWith('.d')) fs.mkdirSync(path.join(root, f));
    else fs.writeFileSync(path.join(root, f), '{}');
  }
  assert.deepEqual(managedPolicySources({ platform: 'darwin', root, configDir: '/home/u/.claude', user: 'u' }), mac.map((f) => path.join(root, f)));
  assert.deepEqual(managedPolicySources({ platform: 'linux', root, configDir: '/home/u/.claude', user: 'u' }), [...linux, '/home/u/.claude/remote-settings.json'].map((f) => path.join(root, f)));
});

test('managedPolicySources on WSL: Windows registry policy counts, and an unanswerable query is unverified', () => {
  const root = scratch('wsl');
  const asked = [];
  const probe = (states) => managedPolicySources({ platform: 'linux', root, configDir: '/c', wsl: true, query: (k) => (asked.push(k), states[k.slice(0, 4)]) });
  assert.deepEqual(probe({ HKLM: 'absent', HKCU: 'absent' }), []);
  assert.deepEqual(asked, ['HKLM\\SOFTWARE\\Policies\\ClaudeCode', 'HKCU\\SOFTWARE\\Policies\\ClaudeCode']);
  assert.deepEqual(probe({ HKLM: 'present', HKCU: 'absent' }), ['HKLM\\SOFTWARE\\Policies\\ClaudeCode Settings']);
  assert.deepEqual(probe({ HKLM: 'unknown', HKCU: 'unknown' }).map((s) => s.includes('unverified')), [true, true]);
  const never = () => assert.fail('the registry must not be queried');
  assert.deepEqual(managedPolicySources({ platform: 'linux', root, configDir: '/c', wsl: false, query: never }), []);
  process.env.WSL_DISTRO_NAME ??= 'test'; // look like WSL, so only the re-rooting keeps the registry out
  try {
    assert.deepEqual(managedPolicySources({ platform: 'linux', root, configDir: '/c', query: never }), [], 'a re-rooted probe never touches the live registry');
  } finally {
    if (process.env.WSL_DISTRO_NAME === 'test') delete process.env.WSL_DISTRO_NAME;
  }
});

test('mcp-tap: a large final response reaches a slow-reading CLI in full', async () => {
  const dir = scratch('tapslow');
  const server = 'process.stdout.write(Buffer.alloc(2 << 20, 98), () => process.exit(0))';
  const tapped = spawn(process.execPath, [TAP, path.join(dir, 'sent.log'), path.join(dir, 'received.log'), process.execPath, '-e', server], { stdio: ['pipe', 'pipe', 'inherit'] });
  tapped.stdout.pause(); // the CLI is busy: the server finishes and exits before anything is read
  let got = 0;
  setTimeout(() => {
    tapped.stdout.on('data', (d) => (got += d.length));
    tapped.stdout.resume();
  }, 300);
  await new Promise((r) => tapped.on('close', r));
  assert.equal(got, 2 << 20);
});

test('mcp-tap: nothing reaches the other side before it is recorded', async () => {
  // The sent log is a FIFO nobody drains: a disk that stalls. A tap that records
  // first must stall too; one that forwards first would deliver everything.
  const dir = scratch('tapfifo');
  const fifo = path.join(dir, 'sent.fifo');
  assert.equal(spawnSync('mkfifo', [fifo]).status, 0);
  const reader = fs.openSync(fifo, fs.constants.O_RDONLY | fs.constants.O_NONBLOCK);
  const server = 'process.stdout.write(Buffer.alloc(1 << 20, 97)); setInterval(() => {}, 1000)';
  const tapped = spawn(process.execPath, [TAP, fifo, path.join(dir, 'received.log'), process.execPath, '-e', server], { stdio: ['pipe', 'pipe', 'inherit'], detached: true });
  let forwarded = 0;
  tapped.stdout.on('data', (d) => (forwarded += d.length));
  await new Promise((r) => setTimeout(r, 800));
  process.kill(-tapped.pid, 'SIGKILL'); // the tap and its server
  await new Promise((r) => tapped.on('close', r));
  let recorded = 0;
  const buf = Buffer.alloc(1 << 16);
  for (;;) {
    let n = 0;
    try {
      n = fs.readSync(reader, buf);
    } catch (e) {
      if (e.code !== 'EAGAIN') throw e;
    }
    if (!n) break;
    recorded += n;
  }
  fs.closeSync(reader);
  assert.ok(recorded > 0, 'the tap recorded into the log');
  assert.ok(forwarded <= recorded, `forwarded ${forwarded} bytes, but only ${recorded} were recorded`);
});

async function getBalance(env) {
  const w = wrapServer({ command: process.execPath, args: [BILLING], env }, tap(scratch('srv')));
  const child = spawn(w.command, w.args, { stdio: ['pipe', 'pipe', 'inherit'] });
  const lines = readline.createInterface({ input: child.stdout })[Symbol.asyncIterator]();
  const send = async (id, method, params) => {
    child.stdin.write(`${JSON.stringify({ jsonrpc: '2.0', id, method, params })}\n`);
    return JSON.parse((await lines.next()).value);
  };
  await send(1, 'initialize', { protocolVersion: '2025-06-18', capabilities: {} });
  const res = await send(2, 'tools/call', { name: 'get_balance', arguments: { account: 'acct_demo' } });
  child.stdin.end();
  return res.result.content[0].text;
}

test('example server: safe mode returns only the balance, debug mode leaks the key as base64', async () => {
  const key = { label: 'billing-api-key', value: makeCanary({ prefix: 'sk_test_FAKE' }) };
  const safe = await getBalance({ BILLING_API_KEY: key.value });
  assert.equal(JSON.parse(safe).balance_cents, 123456);
  assert.deepEqual(findLeaks(safe, [key]), []);
  const leaky = await getBalance({ BILLING_API_KEY: key.value, BILLING_DEBUG: '1' });
  assert.ok(!leaky.includes(key.value), 'the leak is not in raw form');
  assert.ok(findLeaks(leaky, [key]).some((l) => l.form.startsWith('base64')));
});

test('runSession: a session that ignores SIGTERM is killed with its whole process group', { timeout: 20_000 }, async () => {
  const dir = scratch('hang');
  const mcpConfig = path.join(dir, 'mcp.json');
  // The server ignores EOF and SIGTERM too, so killing only the CLI would leave it running.
  const stubborn = wrapServer({ command: process.execPath, args: [path.join(ROOT, 'test', 'fixtures', 'stubborn-server.mjs')] }, tap(dir));
  fs.writeFileSync(mcpConfig, JSON.stringify({ mcpServers: { stubborn } }));
  process.env.FAKE_HANG = '1';
  process.env.FAKE_IGNORE_SIGTERM = '1';
  try {
    const args = claudeArgs({ mcpConfig, allowedTools: ['mcp__stubborn'], maxTurns: 1, budget: 0.1, prompt: 'hi' });
    const started = Date.now();
    // Generous timeout: the CLI must be up (handler installed) before SIGTERM, or
    // it dies of SIGTERM and the escalation path is never exercised.
    const res = await runSession({ bin: FAKE_CLAUDE, args, cwd: dir, streamFile: path.join(dir, 'stream.jsonl'), timeoutMs: 1500, killGraceMs: 300 });
    assert.ok(res.session.init, 'the CLI was up and ignoring SIGTERM');
    assert.equal(res.timedOut, true);
    assert.equal(res.signal, 'SIGKILL');
    assert.ok(Date.now() - started < 10_000);
    // Killed members may linger as zombies for a moment before they are reaped.
    const alive = () => {
      try {
        process.kill(-res.pgid, 0);
        return true;
      } catch (e) {
        return e.code !== 'ESRCH';
      }
    };
    for (let i = 0; i < 40 && alive(); i++) await new Promise((r) => setTimeout(r, 50));
    assert.equal(alive(), false, 'no process of the session (CLI, tap, server) survives');
  } finally {
    delete process.env.FAKE_HANG;
    delete process.env.FAKE_IGNORE_SIGTERM;
  }
});

function harness(suite, env = {}, extra = []) {
  const out = scratch('runs');
  const r = spawnSync(process.execPath, [path.join(ROOT, 'scripts', 'run.mjs'), suite, '--claude-bin', FAKE_CLAUDE, '--out', out, ...extra], { cwd: ROOT, encoding: 'utf8', env: { ...process.env, MCP_SAFETY_KILL_GRACE_MS: '300', MCP_SAFETY_MANAGED_ROOT: scratch('nopolicy'), ...env } });
  const runDir = fs.readdirSync(out).map((d) => path.join(out, d))[0];
  const reportFile = runDir && path.join(runDir, 'report.json');
  return { ...r, runDir, report: reportFile && fs.existsSync(reportFile) ? JSON.parse(fs.readFileSync(reportFile, 'utf8')) : null };
}
const BALANCE = { FAKE_TOOL: 'get_balance', FAKE_ARGS: '{"account":"acct_demo"}', FAKE_ANSWER: 'acct_demo has $1,234.56.' };
const keyOf = (runDir) => JSON.parse(fs.readFileSync(path.join(runDir, 'balance', 'mcp.json'), 'utf8')).mcpServers.billing.args.find((a) => a.startsWith('BILLING_API_KEY=')).split('=')[1];
const leakedIn = (r) => r.report.runs[0].sweep.filter((x) => x.leaks.length).map((x) => path.basename(x.artifact)).sort();

test('run.mjs: the safe example passes end to end', () => {
  const r = harness('examples/billing-safe.suite.mjs', BALANCE);
  assert.equal(r.status, 0, r.stdout + r.stderr);
  assert.equal(r.report.pass, true);
  assert.ok(r.report.runs[0].checks.every((c) => c.ok));
  assert.deepEqual(r.report.runs[0].sweep.flatMap((x) => x.leaks), []);
  assert.equal(r.report.runs[0].canaries[0], 'billing-api-key');
  const swept = r.report.runs[0].sweep.map((x) => path.basename(x.artifact));
  assert.ok(swept.includes('mcp-billing.sent.log') && swept.includes('mcp-billing.received.log'), 'the server taps are swept');
});

test('run.mjs: the leaky control fails with the leak located, and no report repeats it', () => {
  const r = harness('examples/billing-leaky.suite.mjs', BALANCE);
  assert.equal(r.status, 1, r.stdout + r.stderr);
  assert.match(r.stdout, /LEAK DETECTED/);
  assert.deepEqual(leakedIn(r), ['billing.jsonl', 'mcp-billing.sent.log', 'session.stream.jsonl']);
  const key = { label: 'k', value: keyOf(r.runDir) };
  for (const text of [fs.readFileSync(path.join(r.runDir, 'report.md'), 'utf8'), fs.readFileSync(path.join(r.runDir, 'report.json'), 'utf8'), r.stdout, r.stderr]) {
    assert.deepEqual(findLeaks(text, [key]), []);
  }
  assert.match(fs.readFileSync(path.join(r.runDir, 'report.md'), 'utf8'), /\[CANARY:billing-api-key\]/);
});

test('run.mjs: a canary in tool metadata (tools/list) is caught by the tap', () => {
  const r = harness(EDGE, { MCP_SAFETY_FIXTURE: 'metadata-leak', FAKE_TOOL: 'ping' });
  assert.equal(r.status, 1, r.stdout + r.stderr);
  assert.deepEqual(leakedIn(r), ['mcp-describe.sent.log'], 'only the metadata carried it');
});

test('run.mjs: answering without the tools fails (no vacuous pass)', () => {
  const r = harness('examples/billing-safe.suite.mjs', { FAKE_ANSWER: 'I would rather not.' });
  assert.equal(r.status, 1);
  assert.match(r.stdout, /used its tools \(0 calls/);
});

test('run.mjs: a suite that declares no canaries cannot pass (the sweep would prove nothing)', () => {
  const r = harness('test/fixtures/no-canary.suite.mjs', BALANCE);
  assert.equal(r.status, 1, r.stdout + r.stderr);
  assert.match(r.stdout, /declared no canaries/);
});

test('run.mjs: an empty runtime canary fails instead of sweeping for nothing', () => {
  const r = harness(EDGE, { MCP_SAFETY_FIXTURE: 'empty-canary', ...BALANCE });
  assert.equal(r.status, 1, r.stdout + r.stderr);
  assert.match(r.stdout, /canary "runtime-key" is empty or under 8 chars/);
});

test('run.mjs: auto memory reported by the CLI fails isolation', () => {
  const mem = scratch('mem');
  fs.writeFileSync(path.join(mem, 'MEMORY.md'), '- a memory\n');
  const r = harness('examples/billing-safe.suite.mjs', { ...BALANCE, FAKE_MEMORY_DIR: mem });
  assert.equal(r.status, 1, r.stdout + r.stderr);
  assert.match(r.stdout, /auto memory held: MEMORY\.md/);
});

test('run.mjs: removes the empty memory dir the CLI made for its temp cwd, and nothing else', () => {
  const root = scratch('projects');
  fs.mkdirSync(path.join(root, 'unrelated', 'memory'), { recursive: true });
  const r = harness('examples/billing-safe.suite.mjs', { ...BALANCE, FAKE_MEMORY_ROOT: root });
  assert.equal(r.status, 0, r.stdout + r.stderr);
  assert.deepEqual(fs.readdirSync(root), ['unrelated']);
});

test('run.mjs: never removes a memory dir that is not empty, or not named for its own cwd', () => {
  const root = scratch('projects');
  const foreign = path.join(root, 'someone-else', 'memory');
  fs.mkdirSync(foreign, { recursive: true });
  assert.equal(harness('examples/billing-safe.suite.mjs', { ...BALANCE, FAKE_MEMORY_DIR: foreign }).status, 0);
  assert.ok(fs.existsSync(foreign), 'a project dir named for another cwd is left alone');
  const r = harness('examples/billing-safe.suite.mjs', { ...BALANCE, FAKE_MEMORY_ROOT: root, FAKE_MEMORY_FILE: 'notes.txt' });
  assert.equal(r.status, 0, r.stdout + r.stderr);
  const ours = fs.readdirSync(root).filter((d) => d !== 'someone-else');
  assert.equal(ours.length, 1);
  assert.ok(fs.existsSync(path.join(root, ours[0], 'memory', 'notes.txt')), 'a non-empty dir is left alone');
});

test('run.mjs: a server still writing its log after the CLI exits is swept complete', { timeout: 30_000 }, () => {
  const r = harness(EDGE, { MCP_SAFETY_FIXTURE: 'flush-on-exit', FAKE_TOOL: 'ping', MCP_SAFETY_KILL_GRACE_MS: '3000' });
  assert.equal(r.status, 1, r.stdout + r.stderr);
  assert.deepEqual(leakedIn(r), ['flush.jsonl'], 'the record written after the CLI exited was swept');
});

test('run.mjs: managed policy fails isolation unless --allow-managed, and is always reported', () => {
  const root = scratch('policy');
  const dir = process.platform === 'darwin' ? '/Library/Application Support/ClaudeCode' : '/etc/claude-code';
  const file = path.join(root, dir, 'managed-settings.json');
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, '{"hooks":{}}');
  const refused = harness('examples/billing-safe.suite.mjs', { ...BALANCE, MCP_SAFETY_MANAGED_ROOT: root });
  assert.equal(refused.status, 1, refused.stdout + refused.stderr);
  assert.match(refused.stdout, /managed policy present: .*managed-settings\.json \(rerun with --allow-managed/);
  const allowed = harness('examples/billing-safe.suite.mjs', { ...BALANCE, MCP_SAFETY_MANAGED_ROOT: root }, ['--allow-managed']);
  assert.equal(allowed.status, 0, allowed.stdout + allowed.stderr);
  assert.deepEqual(allowed.report.managedPolicy, { files: [file], allowed: true });
  assert.match(fs.readFileSync(path.join(allowed.runDir, 'report.md'), 'utf8'), /Managed policy: allowed by --allow-managed: .*managed-settings\.json/);
});

test('run.mjs: managed policy that appears during a session fails isolation', () => {
  const root = scratch('policy');
  const cache = path.join(root, 'cfg', 'remote-settings.json'); // where a server-managed fetch lands
  fs.mkdirSync(path.dirname(cache), { recursive: true });
  const env = { ...BALANCE, MCP_SAFETY_MANAGED_ROOT: root, CLAUDE_CONFIG_DIR: '/cfg', FAKE_TOUCH: cache };
  const r = harness('examples/billing-safe.suite.mjs', env);
  assert.equal(r.status, 1, r.stdout + r.stderr);
  assert.match(r.stdout, /managed policy appeared or changed during the session: .*remote-settings\.json/);
  fs.rmSync(cache);
  assert.equal(harness('examples/billing-safe.suite.mjs', env, ['--allow-managed']).status, 0);
});

test('run.mjs: a temp dir under project context is refused with exit 2', () => {
  const r = harness('examples/billing-safe.suite.mjs', { ...BALANCE, TMPDIR: scratch('tmpdir') }); // inside this git repo
  assert.equal(r.status, 2, r.stdout + r.stderr);
  assert.match(r.stderr, /sits under project context \(.+\)/); // .git here; .claude from an installed copy
});

test('run.mjs: the during() hook watches the live session', () => {
  const r = harness('test/fixtures/during.suite.mjs', BALANCE);
  assert.equal(r.status, 0, r.stdout + r.stderr);
});

test('run.mjs: refuses to pass a credential from your environment to a server, even multiline', () => {
  for (const value of ['real-looking-token-0123456789', '-----BEGIN FAKE KEY-----\nabcdefghijklmnop\n-----END FAKE KEY-----']) {
    const r = harness('test/fixtures/real-credential.suite.mjs', { HARNESS_TEST_TOKEN: value });
    assert.equal(r.status, 2, r.stdout + r.stderr);
    assert.match(r.stderr, /HARNESS_TEST_TOKEN/);
    assert.ok(!(r.stdout + r.stderr).includes('abcdefghijklmnop') && !(r.stdout + r.stderr).includes('real-looking-token'));
  }
});

test('run.mjs: refuses a ${VAR} that Claude Code would expand from your environment', () => {
  const r = harness(EDGE, { MCP_SAFETY_FIXTURE: 'host-env-ref', HARNESS_TEST_TOKEN: 'real-looking-token-0123456789' });
  assert.equal(r.status, 2, r.stdout + r.stderr);
  assert.match(r.stderr, /would be expanded by Claude Code/);
});

test('run.mjs: a session with no result event counts its budget cap toward --max-total-usd', { timeout: 30_000 }, () => {
  const r = harness(EDGE, { MCP_SAFETY_FIXTURE: 'hang', FAKE_HANG: '1' }, ['--max-total-usd', '0.2']);
  assert.equal(r.status, 1, r.stdout + r.stderr);
  assert.match(r.stdout, /cost=unknown \(counted as the \$0\.2 cap\)/);
  assert.match(r.stdout, /skipped after reaching --max-total-usd: two/);
  assert.equal(r.report.runs.length, 1);
});

test('run.mjs: the CLI gets the isolation flags, the model, and a temp cwd that is removed after', () => {
  const argvFile = path.join(scratch('argv'), 'argv.json');
  harness('examples/billing-safe.suite.mjs', { ...BALANCE, FAKE_ARGV: argvFile }, ['--model', 'some-model']);
  const { argv, cwd } = JSON.parse(fs.readFileSync(argvFile, 'utf8'));
  assert.equal(argv[argv.indexOf('--model') + 1], 'some-model');
  assert.equal(argv[argv.indexOf('--tools') + 1], '');
  assert.equal(argv[argv.indexOf('--setting-sources') + 1], '');
  assert.equal(argv[argv.indexOf('--allowedTools') + 1], 'mcp__billing');
  assert.ok(cwd.startsWith(fs.realpathSync(os.tmpdir())), cwd);
  assert.ok(!fs.existsSync(cwd), 'the session cwd was cleaned up');
});

test('run.mjs: usage errors exit 2 and --dry-run spends nothing', () => {
  assert.equal(harness('examples/billing-safe.suite.mjs', {}, ['--bogus']).status, 2);
  assert.equal(harness('examples/billing-safe.suite.mjs', {}, ['--only', 'nope']).status, 2);
  const dry = harness('examples/billing-safe.suite.mjs', {}, ['--dry-run']);
  assert.equal(dry.status, 0);
  assert.match(dry.stdout, /--setting-sources '' --strict-mcp-config/);
  assert.ok(!fs.existsSync(path.join(dry.runDir, 'balance', 'session.stream.jsonl')), 'no session was started');
});
