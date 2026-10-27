// A suite file's shape, its validation, and how a run is judged.
//
// Judging is ground truth only: the CLI's own init event (which tools and MCP
// servers were really loaded), the tool calls and results in the stream, and
// whatever the scenario's `expect` reads from the servers' own state. Never
// the model's description of what it did.

const SUITE_KEYS = new Set(['name', 'model', 'system', 'servers', 'allowedTools', 'canaries', 'artifacts', 'scenarios']);
const SCENARIO_KEYS = new Set(['id', 'name', 'prompt', 'system', 'allowedTools', 'maxTurns', 'budget', 'timeoutMs', 'minToolCalls', 'canaries', 'during', 'expect']);
export const DEFAULTS = { maxTurns: 20, budget: 0.5, timeoutMs: 8 * 60_000, minToolCalls: 1 };

const isFn = (v) => typeof v === 'function';
const isStrings = (v) => Array.isArray(v) && v.every((x) => typeof x === 'string' && x);

// Shorter values have no distinctive derived forms, and an empty one has no
// form at all: the sweep would search for nothing and pass.
export const MIN_CANARY = 8;
// Problems with resolved canaries, naming labels only (never values).
export function canaryProblems(canaries) {
  if (!Array.isArray(canaries)) return ['canaries must resolve to a list of { label, value }'];
  return canaries.flatMap((c, i) => {
    const name = typeof c?.label === 'string' && c.label ? `"${c.label}"` : `#${i + 1}`;
    if (typeof c?.label !== 'string' || !c.label) return [`canary ${name} needs a non-empty label`];
    if (typeof c.value !== 'string' || c.value.length < MIN_CANARY) return [`canary ${name} is empty or under ${MIN_CANARY} chars, so the sweep could not find it`];
    return [];
  });
}
const canariesOk = (v) => v === undefined || isFn(v) || (Array.isArray(v) && canaryProblems(v).length === 0);

// Throws one error listing every problem, so a broken suite is fixed in one pass.
export function validateSuite(suite) {
  const problems = [];
  if (!suite || typeof suite !== 'object') throw new Error('suite file must `export default` an object');
  for (const k of Object.keys(suite)) if (!SUITE_KEYS.has(k)) problems.push(`unknown suite key "${k}"`);
  if (!isFn(suite.servers) && (typeof suite.servers !== 'object' || !suite.servers)) problems.push('servers must be an object or a function (ctx) => object');
  if (suite.allowedTools !== undefined && !isStrings(suite.allowedTools)) problems.push('allowedTools must be a list of tool names');
  if (!canariesOk(suite.canaries)) problems.push(`canaries must be [{ label, value }] (values of ${MIN_CANARY}+ chars) or a function (ctx) => that list`);
  if (suite.artifacts !== undefined && !isFn(suite.artifacts)) problems.push('artifacts must be a function (ctx) => [file paths]');
  if (!Array.isArray(suite.scenarios) || !suite.scenarios.length) problems.push('scenarios must be a non-empty list');
  const ids = new Set();
  for (const [i, s] of (Array.isArray(suite.scenarios) ? suite.scenarios : []).entries()) {
    const at = `scenario ${s?.id ?? `#${i + 1}`}`;
    for (const k of Object.keys(s ?? {})) if (!SCENARIO_KEYS.has(k)) problems.push(`${at}: unknown key "${k}"`);
    if (!/^[A-Za-z0-9_-]{1,40}$/.test(String(s?.id))) problems.push(`${at}: id must be 1-40 letters, digits, _ or -`);
    else if (ids.has(s.id)) problems.push(`${at}: duplicate id`);
    ids.add(s?.id);
    if (typeof s?.prompt !== 'string' || !s.prompt.trim()) problems.push(`${at}: prompt must be a non-empty string`);
    else if (s.prompt.startsWith('-')) problems.push(`${at}: prompt must not start with "-" (the CLI would read it as a flag)`);
    for (const k of ['maxTurns', 'budget', 'timeoutMs']) if (s?.[k] !== undefined && !(Number(s[k]) > 0)) problems.push(`${at}: ${k} must be a positive number`);
    if (s?.minToolCalls !== undefined && !(Number.isInteger(s.minToolCalls) && s.minToolCalls >= 0)) problems.push(`${at}: minToolCalls must be an integer >= 0`);
    if (s?.allowedTools !== undefined && !isStrings(s.allowedTools)) problems.push(`${at}: allowedTools must be a list of tool names`);
    if (!canariesOk(s?.canaries)) problems.push(`${at}: canaries must be [{ label, value }] (values of ${MIN_CANARY}+ chars) or a function`);
    for (const k of ['during', 'expect']) if (s?.[k] !== undefined && !isFn(s[k])) problems.push(`${at}: ${k} must be a function`);
  }
  if (problems.length) throw new Error(`invalid suite:\n  - ${problems.join('\n  - ')}`);
  return { name: suite.name ?? 'suite', ...suite, scenarios: suite.scenarios.map((s) => ({ ...DEFAULTS, name: s.id, ...s })) };
}

const NAME_RE = /^[A-Za-z_][A-Za-z0-9_]*$/;
export function validateServers(servers) {
  const problems = [];
  if (!servers || typeof servers !== 'object' || !Object.keys(servers).length) problems.push('servers must declare at least one MCP server');
  for (const [name, s] of Object.entries(servers ?? {})) {
    if (!/^[A-Za-z0-9_-]+$/.test(name) || name.includes('__')) problems.push(`server "${name}": name must be letters, digits, _ or - (no "__")`);
    if (typeof s?.command !== 'string' || !s.command) problems.push(`server "${name}": command is required`);
    // `env -i` would read these as an assignment or an option.
    else if (s.command.includes('=') || s.command.startsWith('-')) problems.push(`server "${name}": command must not contain "=" or start with "-"`);
    if (s?.args !== undefined && !(Array.isArray(s.args) && s.args.every((a) => typeof a === 'string'))) problems.push(`server "${name}": args must be strings`);
    for (const [k, v] of Object.entries(s?.env ?? {})) {
      if (!NAME_RE.test(k)) problems.push(`server "${name}": bad env name "${k}"`);
      if (typeof v !== 'string' || v.includes('\0')) problems.push(`server "${name}": env ${k} must be a string`);
    }
  }
  if (problems.length) throw new Error(`invalid servers:\n  - ${problems.join('\n  - ')}`);
  return servers;
}

// Helpers handed to `expect(run, check)`. `name` is a full tool name
// (mcp__billing__get_balance) or a server prefix (mcp__billing) for any of its tools.
const matches = (call, name) => call.name === name || call.name.startsWith(`${name}__`);
const callsOf = (run, name) => run.session.toolCalls.filter((c) => matches(c, name));
export const check = {
  calls: callsOf,
  called: (run, name) => callsOf(run, name).length > 0,
  neverCalled: (run, name) => callsOf(run, name).length === 0,
  succeeded: (run, name, pred = () => true) => callsOf(run, name).some((c) => c.isError === false && pred(c)),
  failed: (run, name, pred = () => true) => callsOf(run, name).some((c) => c.isError === true && pred(c)),
};

// From the CLI's own init event: only MCP tools; the auto-memory dir it reports
// holds no memory files; and no organization policy, unless explicitly allowed.
// Anything malformed counts as unknown, which fails.
export function isolationCheck(loaded, memory = [], { files = [], changed = [], allowed = false } = {}, keySource) {
  if (!Array.isArray(loaded)) return [false, 'isolation: no usable init event, so the loaded tools are unknown'];
  const builtins = loaded.filter((t) => !String(t).startsWith('mcp__'));
  const policy = !files.length ? 'no managed policy found' : allowed ? `managed policy allowed by --allow-managed: ${files.join(', ')}` : `managed policy present: ${files.join(', ')} (rerun with --allow-managed to accept it)`;
  const parts = [builtins.length ? `built-in tools loaded: ${builtins.join(', ')}` : 'only MCP tools loaded', memory.length ? `auto memory held: ${memory.join(', ')}` : 'auto-memory dir empty', policy];
  if (changed.length) parts.push(`managed policy appeared or changed during the session: ${changed.join(', ')}`);
  if (keySource) parts.push(`CLI-reported key source: ${keySource}`);
  return [builtins.length === 0 && memory.length === 0 && ((files.length === 0 && changed.length === 0) || allowed), `isolation: ${parts.join('; ')}`];
}

// The harness's own checks first, then the scenario's. Each is { ok, what }.
export function evaluate(scenario, run) {
  const { session } = run;
  const servers = Array.isArray(session.init?.mcp_servers) ? session.init.mcp_servers : [];
  const status = new Map(servers.map((s) => [s?.name, s?.status]));
  const notConnected = run.servers.filter((n) => status.get(n) !== 'connected');
  const n = session.toolCalls.length;
  const checks = [
    [run.exitCode === 0 && session.result?.subtype === 'success', `claude -p finished (exit ${run.exitCode}${run.timedOut ? ', timed out' : ''}, ${session.result?.subtype ?? 'no result event'})`],
    isolationCheck(session.init?.tools, run.autoMemory, run.managed, session.init?.apiKeySource),
    [notConnected.length === 0, `MCP servers connected: ${run.servers.map((s) => `${s}=${status.get(s) ?? 'missing'}`).join(', ')}`],
  ];
  // A model that refuses, or answers without touching its tools, proves nothing.
  if (scenario.minToolCalls > 0) checks.push([n >= scenario.minToolCalls, `the model used its tools (${n} call${n === 1 ? '' : 's'}, need ≥ ${scenario.minToolCalls}); a refusal cannot pass`]);
  if (scenario.expect) {
    try {
      for (const r of scenario.expect(run, check) ?? []) checks.push(Array.isArray(r) ? r : [r?.ok, r?.what]);
    } catch (e) {
      checks.push([false, `expect() threw: ${e.message}`]);
    }
  }
  if (run.duringError) checks.push([false, `during() hook failed: ${run.duringError}`]);
  return checks.map(([ok, what]) => ({ ok: ok === true, what: String(what ?? '(unnamed check)') }));
}
