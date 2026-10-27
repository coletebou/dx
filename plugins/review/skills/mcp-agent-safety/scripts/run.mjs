#!/usr/bin/env node
// Real-LLM safety run for MCP servers: a headless Claude Code session per
// scenario, with only the suite's MCP servers loaded, then every artifact swept
// for the suite's canaries and every scenario judged on ground truth.
//
//   node scripts/run.mjs <suite.mjs> [--model ID] [--only a,b] [--out DIR]
//                        [--max-total-usd N] [--allow-managed] [--dry-run] [--claude-bin PATH]
//
// Exit 0 = every scenario did its job and nothing leaked; 1 = a leak or an
// unmet expectation; 2 = usage or configuration error.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { claudeArgs, commandLine, envCredentialHits, isolatedCwd, makeCanary, managedPolicySnapshot, managedPolicySources, removeEmptyMemoryDir, runSession, serverConfigProblems, wrapServer } from './lib/claude.mjs';
import { findLeaks, leakExcerpts, redact } from './lib/leaks.mjs';
import { canaryProblems, evaluate, validateServers, validateSuite } from './lib/scenario.mjs';

const USAGE = 'usage: node scripts/run.mjs <suite.mjs> [--model ID] [--only a,b] [--out DIR] [--max-total-usd N] [--allow-managed] [--dry-run] [--claude-bin PATH]';
const VALUE_FLAGS = new Set(['model', 'only', 'out', 'max-total-usd', 'claude-bin']);

function parseCli(argv) {
  const opts = { files: [] };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--dry-run') opts.dryRun = true;
    else if (a === '--allow-managed') opts.allowManaged = true;
    else if (a === '-h' || a === '--help') opts.help = true;
    else if (a.startsWith('--') && VALUE_FLAGS.has(a.slice(2))) {
      if (i + 1 >= argv.length) throw new Error(`${a} needs a value`);
      opts[a.slice(2)] = argv[++i];
    } else if (a.startsWith('-')) throw new Error(`unknown flag ${a}`);
    else opts.files.push(a);
  }
  if (!opts.help && opts.files.length !== 1) throw new Error('give exactly one suite file');
  if (opts['max-total-usd'] !== undefined && !(Number(opts['max-total-usd']) > 0)) throw new Error('--max-total-usd must be a positive number');
  return opts;
}

const fail = (msg) => {
  console.error(msg);
  process.exit(2);
};

let opts;
try {
  opts = parseCli(process.argv.slice(2));
} catch (e) {
  fail(`${e.message}\n${USAGE}`);
}
if (opts.help) {
  console.log(USAGE);
  process.exit(0);
}

const suiteFile = path.resolve(opts.files[0]);
let suite;
try {
  suite = validateSuite((await import(pathToFileURL(suiteFile).href)).default);
} catch (e) {
  fail(`${path.relative(process.cwd(), suiteFile)}: ${e.message}`);
}
const only = opts.only ? new Set(opts.only.split(',')) : null;
const unknown = only ? [...only].filter((id) => !suite.scenarios.some((s) => s.id === id)) : [];
if (unknown.length) fail(`--only: no scenario ${unknown.join(', ')}`);
const scenarios = suite.scenarios.filter((s) => !only || only.has(s.id));
const model = opts.model ?? suite.model ?? process.env.MCP_SAFETY_MODEL;
const bin = opts['claude-bin'] ?? 'claude';
const maxTotal = opts['max-total-usd'] === undefined ? Infinity : Number(opts['max-total-usd']);
// How long a timed-out session gets between SIGTERM and SIGKILL (tests shorten it).
const killGraceMs = Number(process.env.MCP_SAFETY_KILL_GRACE_MS) || 5000;
// Organization policy the CLI loads whatever the flags. It fails isolation unless
// --allow-managed; either way the report lists it. (Tests re-root the probe.)
const policyRoot = process.env.MCP_SAFETY_MANAGED_ROOT || '/';
const managed = { files: managedPolicySources({ root: policyRoot }), allowed: Boolean(opts.allowManaged) };
if (managed.files.length) console.log(`${managed.allowed ? '⚠️  managed policy allowed' : '❌ managed policy present'}: ${managed.files.join(', ')}`);

const stamp = new Date().toISOString().replace(/[:.]/g, '-');
const slug = String(suite.name).toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '').slice(0, 40) || 'suite';
const runDir = path.resolve(opts.out ?? '.agent-safety', `${stamp}-${slug}`);
fs.mkdirSync(runDir, { recursive: true, mode: 0o700 });

const resolveList = async (v, ctx) => (typeof v === 'function' ? await v(ctx) : v) ?? [];
const readText = (file) => (fs.existsSync(file) ? fs.readFileSync(file, 'utf8') : '');
const clip = (s, n) => (s.length > n ? `${s.slice(0, n)}…` : s);
// Where the tap records one server's traffic: written by the wrapper, swept after.
const tapFiles = (dir, name) => ({ sentFile: path.join(dir, `mcp-${name}.sent.log`), receivedFile: path.join(dir, `mcp-${name}.received.log`) });

async function runScenario(s) {
  const dir = path.join(runDir, s.id);
  const home = path.join(dir, 'server-home');
  for (const d of [dir, home]) fs.mkdirSync(d, { recursive: true, mode: 0o700 });
  const generated = [];
  const ctx = {
    dir,
    scenario: s.id,
    canary(label, options) {
      const value = makeCanary(options);
      generated.push({ label, value });
      return value;
    },
  };
  const servers = validateServers(typeof suite.servers === 'function' ? await suite.servers(ctx) : suite.servers);
  // Every byte each server sends or receives, including the tool metadata the
  // model sees before any call, is tapped into these files and swept.
  const taps = Object.keys(servers).flatMap((n) => Object.values(tapFiles(dir, n)));
  const wrapped = Object.fromEntries(Object.entries(servers).map(([n, spec]) => [n, wrapServer(spec, { home, ...tapFiles(dir, n) })]));
  // Never hand a server a real credential, directly or as a ${VAR} for Claude Code to expand.
  const unsafe = serverConfigProblems(wrapped);
  if (unsafe.length) fail(`scenario ${s.id}: refusing to run:\n  - ${unsafe.join('\n  - ')}`);
  const mcpConfig = path.join(dir, 'mcp.json');
  fs.writeFileSync(mcpConfig, JSON.stringify({ mcpServers: wrapped }, null, 2), { mode: 0o600 });

  const allowedTools = s.allowedTools ?? suite.allowedTools ?? Object.keys(servers).map((n) => `mcp__${n}`);
  const system = [suite.system, s.system].filter(Boolean).join('\n\n') || undefined;
  const args = claudeArgs({ model, mcpConfig, allowedTools, maxTurns: s.maxTurns, budget: s.budget, system, prompt: s.prompt });
  if (opts.dryRun) return { id: s.id, dryRun: true, command: commandLine(bin, args), mcpConfig };

  console.log(`▶ ${s.id}: ${s.name} (model ${model ?? 'CLI default'})`);
  const streamFile = path.join(dir, 'session.stream.jsonl');
  const cwd = isolatedCwd(); // empty, outside any repository: no CLAUDE.md or settings above it
  let ran;
  // Server-managed policy can be fetched by the session itself: compare after.
  const policyBefore = managedPolicySnapshot({ root: policyRoot });
  try {
    ran = await runSession({ bin, args, cwd, streamFile, timeoutMs: s.timeoutMs, during: s.during, killGraceMs });
  } finally {
    fs.rmSync(cwd, { recursive: true, force: true });
  }
  const stderrFile = path.join(dir, 'stderr.txt');
  fs.writeFileSync(stderrFile, ran.stderr, { mode: 0o600 });

  // Ground truth for memory: the auto-memory dir the CLI reported must be empty.
  const memDir = ran.session.init?.memory_paths?.auto;
  const autoMemory = memDir && fs.existsSync(memDir) ? fs.readdirSync(memDir).filter((f) => f.endsWith('.md')) : [];
  if (memDir && !autoMemory.length) removeEmptyMemoryDir(memDir, cwd);
  const policyAfter = managedPolicySnapshot({ root: policyRoot });
  const changed = [...new Set([...Object.keys(policyBefore), ...Object.keys(policyAfter)])].filter((k) => policyBefore[k] !== policyAfter[k]);
  const run = { ...ran, servers: Object.keys(servers), dir, autoMemory, managed: { ...managed, changed } };
  // Canaries are collected AFTER the run, so secrets created during it count too.
  const resolved = [...generated, ...(await resolveList(suite.canaries, ctx)), ...(await resolveList(s.canaries, ctx))];
  const unusable = canaryProblems(resolved);
  const canaries = resolved.filter((c) => canaryProblems([c]).length === 0);
  const files = [streamFile, stderrFile, ...taps, ...(await resolveList(suite.artifacts, ctx))];
  // Entries never hold the artifact text: a report must not be one step from the raw canaries.
  const sweep = files.map((file) => {
    const text = readText(file);
    return { artifact: path.relative(runDir, file), bytes: Buffer.byteLength(text), leaks: findLeaks(text, canaries), excerpts: leakExcerpts(text, canaries), realCredentials: envCredentialHits(text) };
  });
  const checks = evaluate(s, run);
  if (!resolved.length) checks.push({ ok: false, what: 'the suite declared no canaries, so the sweep proves nothing' });
  for (const p of unusable) checks.push({ ok: false, what: p });
  const result = ran.session.result;
  // No result event (a timeout, a crash): the spend is unknown, so count the cap.
  const costKnown = typeof result?.total_cost_usd === 'number';
  console.log(`  exit=${ran.exitCode} turns=${result?.num_turns ?? '?'} cost=${costKnown ? `$${result.total_cost_usd.toFixed(4)}` : `unknown (counted as the $${s.budget} cap)`} ${result?.subtype ?? 'no result'}${ran.timedOut ? ' (timed out)' : ''}`);
  for (const c of checks) console.log(`  ${c.ok ? '✅' : '❌'} ${c.what}`);
  const leaks = sweep.flatMap((x) => x.leaks.map((l) => ({ ...l, artifact: x.artifact })));
  console.log(`  ${leaks.length ? '❌' : '✅'} sweep: ${canaries.length} canar${canaries.length === 1 ? 'y' : 'ies'} across ${sweep.length} artifacts, ${leaks.length ? `LEAKED: ${leaks.map((l) => `${l.label} as ${l.form} in ${l.artifact}`).join('; ')}` : 'no leaks'}`);
  return {
    id: s.id,
    name: s.name,
    prompt: s.prompt,
    exitCode: ran.exitCode,
    timedOut: ran.timedOut,
    subtype: result?.subtype ?? null,
    turns: result?.num_turns ?? null,
    costUsd: costKnown ? result.total_cost_usd : s.budget,
    costKnown,
    checks,
    canaries: canaries.map((c) => c.label),
    sweep,
    toolCalls: ran.session.toolCalls.map((c) => ({ name: c.name, isError: c.isError, input: clip(redact(JSON.stringify(c.input), canaries), 300), output: clip(redact(c.output ?? '', canaries), 300) })),
    permissionDenials: (result?.permission_denials ?? []).map((d) => d.tool_name ?? String(d)),
    finalAnswer: redact(result?.result ?? '', canaries),
  };
}

const runs = [];
const skipped = [];
let spent = 0;
for (const s of scenarios) {
  if (spent >= maxTotal) {
    skipped.push(s.id);
    continue;
  }
  let r;
  try {
    r = await runScenario(s);
  } catch (e) {
    fail(`scenario ${s.id}: ${e.message}`);
  }
  spent += r.costUsd ?? 0;
  runs.push(r);
}

if (opts.dryRun) {
  for (const r of runs) console.log(`# ${r.id}  (cwd: a fresh empty dir under ${os.tmpdir()})\n${r.command}\n`);
  console.log(`mcp configs (0600, hold the canaries): ${runDir}`);
  process.exit(0);
}

// Your real credentials must not appear in anything this run keeps.
const envHits = [...new Set(runs.flatMap((r) => r.sweep.flatMap((x) => x.realCredentials)))];
const leaked = runs.some((r) => r.sweep.some((x) => x.leaks.length)) || envHits.length > 0;
const unmet = runs.flatMap((r) => r.checks.filter((c) => !c.ok).map((c) => `${r.id}: ${c.what}`));
const pass = !leaked && !unmet.length && !skipped.length;

const report = { suite: suite.name, file: path.relative(process.cwd(), suiteFile), startedAt: stamp, model: model ?? null, totalCostUsd: spent, pass, managedPolicy: managed, envCredentialHits: envHits, skipped, runs };
fs.writeFileSync(path.join(runDir, 'report.json'), `${JSON.stringify(report, null, 2)}\n`, { mode: 0o600 });
fs.writeFileSync(path.join(runDir, 'report.md'), markdown(report), { mode: 0o600 });

const unknownCost = runs.some((r) => r.costKnown === false);
console.log(`\ntotal cost ${unknownCost ? 'at most ' : ''}$${spent.toFixed(4)}${unknownCost ? ' (a session ended without a result event; its cap was counted)' : ''} · report ${path.relative(process.cwd(), path.join(runDir, 'report.md'))}`);
if (envHits.length) console.log(`❌ REAL CREDENTIALS from your environment appear in the artifacts (${envHits.join(', ')}). Do not share ${runDir}.`);
if (leaked) console.log('❌ LEAK DETECTED');
if (unmet.length) console.log(`❌ expectations not met (a no-leak result for these scenarios is vacuous):\n  ${unmet.join('\n  ')}`);
if (skipped.length) console.log(`❌ skipped after reaching --max-total-usd: ${skipped.join(', ')}`);
if (pass) console.log('✅ PASS: every scenario did its job and no canary leaked');
process.exit(pass ? 0 : 1);

function markdown(r) {
  const lines = [
    `# ${r.suite}: ${r.pass ? 'PASS' : 'FAIL'}`,
    '',
    `Suite \`${r.file}\`, model \`${r.model ?? 'CLI default'}\`, started ${r.startedAt}, total $${r.totalCostUsd.toFixed(4)}.`,
    'Headless `claude -p` with only the suite\'s MCP servers: no built-in tools, no user settings, hooks or CLAUDE.md, servers in a minimal environment.',
    '',
    `Real-credential guard (names only): ${r.envCredentialHits.length ? `❌ ${r.envCredentialHits.join(', ')}` : 'no value from your environment appears in any artifact'}.`,
    `Managed policy: ${r.managedPolicy.files.length ? `${r.managedPolicy.allowed ? 'allowed by --allow-managed' : '❌ present'}: ${r.managedPolicy.files.map((f) => `\`${f}\``).join(', ')}` : 'none found'}.`,
    ...(r.skipped.length ? ['', `Skipped (spend cap): ${r.skipped.join(', ')}`] : []),
    '',
  ];
  for (const s of r.runs) {
    lines.push(`## ${s.id}: ${s.name}`, '', `Prompt: ${s.prompt.replace(/\s+/g, ' ')}`, '', `Exit ${s.exitCode}, ${s.turns ?? '?'} turns, ${s.costKnown ? `$${s.costUsd.toFixed(4)}` : `cost unknown (counted as the $${s.costUsd} cap)`}, ${s.subtype ?? 'no result'}${s.timedOut ? ', timed out' : ''}.`, '');
    lines.push(...s.checks.map((c) => `- ${c.ok ? '✅' : '❌'} ${c.what}`), '');
    lines.push(`Canaries: ${s.canaries.join(', ') || 'none'}`, '', '| Artifact | Bytes | Leaks |', '|---|---|---|');
    lines.push(...s.sweep.map((x) => `| ${x.artifact} | ${x.bytes} | ${x.leaks.length ? `❌ ${x.leaks.map((l) => `${l.label} as ${l.form} ×${l.count}`).join(', ')}` : '0'} |`));
    const excerpts = s.sweep.flatMap((x) => x.excerpts.map((e) => `- ${x.artifact}: \`${e.replaceAll('`', "'")}\``));
    if (excerpts.length) lines.push('', 'Where (redacted):', '', ...excerpts);
    lines.push('', 'Tool calls:', '', ...(s.toolCalls.length ? s.toolCalls.map((c) => `- ${c.name}${c.isError ? ' (error)' : ''}: ${c.input} → ${c.output.replace(/\s+/g, ' ')}`) : ['- none']));
    if (s.permissionDenials.length) lines.push('', `Permission denials: ${s.permissionDenials.join(', ')}`);
    lines.push('', 'Final answer (redacted):', '', ...String(s.finalAnswer || '(none)').split('\n').map((l) => `> ${l}`), '');
  }
  return `${lines.join('\n')}\n`;
}
