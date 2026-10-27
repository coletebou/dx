#!/usr/bin/env node
/**
 * PR Labels: keeps the `size/*` and `proof: *` labels on a pull request current.
 *
 * Runs from .github/workflows/pr-labels.yml on PR, comment and review events,
 * and owns exactly two label families. Every other label is left alone,
 * including `merge-risk: *`, which needs a reviewer's judgment.
 *
 *   size/*    Lines changed, not counting lockfiles, generated output or binary
 *             assets. Exactly one size label per PR.
 *   proof: *  What real-behavior evidence the PR carries. Screenshots or a
 *             recording for UI changes; for behavior changes, a command plus
 *             its output, a recording, or a link in the PR body's `## Evidence`
 *             section (or a comment that starts with "Evidence"). Unit tests,
 *             mocks, typecheck and CI alone are not evidence, so a `## Testing`
 *             section full of test runs does not count.
 *
 * `proof: 🙋 override` means a maintainer settled the proof question by hand:
 * while it is on the PR, this script never touches the proof labels.
 *
 * Which files are UI a user sees comes from two optional regular expressions,
 * matched against each changed path (the workflow passes them from repository
 * variables of the same names):
 *   PR_LABELS_UI_PATHS  where UI lives, e.g. ^(web|app/views)/ (default: anywhere)
 *   PR_LABELS_NOT_UI    paths under it that are not UI, e.g. ^web/src/api/
 * A UI file is then a source file of a UI kind (.tsx, .css, .html, .swift, ...)
 * or an image under those paths, and not a test.
 *
 * Usage:
 *   node .github/scripts/pr-labels.mjs                        # in Actions (reads GITHUB_EVENT_PATH)
 *   node .github/scripts/pr-labels.mjs --repo o/r --pr 12 --dry-run   # locally, GITHUB_TOKEN set
 *
 * Rules: .github/docs/pull-requests.md
 */

import { appendFileSync, readFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';

export const PROOF = Object.freeze({
  sufficient: 'proof: ✅ sufficient',
  screenshots: 'proof: 📸 needs screenshots',
  e2e: 'proof: 🧪 needs e2e',
  notNeeded: 'proof: ➖ not needed',
  override: 'proof: 🙋 override',
});

export const SIZES = Object.freeze([
  { name: 'size/XS', below: 20 },
  { name: 'size/S', below: 100 },
  { name: 'size/M', below: 500 },
  { name: 'size/L', below: 1000 },
  { name: 'size/XL', below: Infinity },
]);

// The same colors and descriptions as labels.yml; a label missing from the
// repository is created from these the first time it is needed.
export const LABEL_DEFINITIONS = Object.freeze([
  { name: 'size/XS', color: 'ededed', description: 'Under 20 lines changed (lockfiles and generated files not counted)' },
  { name: 'size/S', color: 'c2e0c6', description: '20-99 lines changed (lockfiles and generated files not counted)' },
  { name: 'size/M', color: 'fbca04', description: '100-499 lines changed (lockfiles and generated files not counted)' },
  { name: 'size/L', color: 'e99695', description: '500-999 lines changed (lockfiles and generated files not counted)' },
  { name: 'size/XL', color: 'b60205', description: '1000+ lines changed; consider splitting before review' },
  { name: PROOF.sufficient, color: '1a7f37', description: 'Real behavior proof covers the change: screenshots for UI, E2E or a live run for behavior' },
  { name: PROOF.screenshots, color: 'd93f0b', description: 'Changes UI a user can see, but the PR has no screenshots or recording of it' },
  { name: PROOF.e2e, color: 'fbca04', description: 'Behavior is only proven by unit tests, mocks, typecheck or CI; needs an E2E or live run' },
  { name: PROOF.notNeeded, color: 'c5def5', description: 'Docs, comments, or a change where CI itself is the real proof' },
  { name: PROOF.override, color: '8250df', description: 'A maintainer settled the proof question by hand; automation leaves proof labels alone' },
]);

const LOCKFILE = /(^|\/)(bun\.lockb?|package-lock\.json|npm-shrinkwrap\.json|pnpm-lock\.yaml|yarn\.lock|Cargo\.lock|Podfile\.lock|Package\.resolved|go\.sum|[^/]+\.lock)$/;
const GENERATED = /(^|\/)(dist|build|coverage|node_modules|vendor)\/|\.min\.(js|css)$|\.snap$|\.generated\./;
const ASSET = /\.(png|jpe?g|gif|ico|svg|webp|avif|woff2?|ttf|otf)$/i;
const DOC = /\.(md|mdx|txt|rst|adoc)$|^docs\/|(^|\/)(LICENSE|NOTICE|AUTHORS|CODEOWNERS)$/;
const TEST = /(^|\/)(tests?|__tests__|spec|e2e|UITests|Tests)\/|[._-](test|spec)\.[a-z]+$|Tests?\.swift$|_test\.(go|py)$|(^|\/)test_[^/]+\.py$/;
const MANIFEST = /(^|\/)package\.json$/;
const UI_SOURCE = /\.(tsx|jsx|css|scss|sass|less|html|astro|swift|vue|svelte)$/;
const NEVER = /(?!)/;

function pattern(source, name, fallback) {
  if (!source) return fallback;
  try {
    return new RegExp(source);
  } catch (error) {
    throw new Error(`${name} is not a valid regular expression (${source}): ${error.message}`);
  }
}

/** The UI path rules, from PR_LABELS_UI_PATHS and PR_LABELS_NOT_UI. */
export function uiRules(env = process.env) {
  return {
    area: pattern(env.PR_LABELS_UI_PATHS, 'PR_LABELS_UI_PATHS', /^/),
    notUi: pattern(env.PR_LABELS_NOT_UI, 'PR_LABELS_NOT_UI', NEVER),
  };
}

/** Size and kind of change, from the PR files API (`filename`, `additions`, `deletions`, `patch`). */
export function classifyFiles(files, rules = uiRules()) {
  let lines = 0;
  let code = 0;
  let lockfiles = 0;
  const ui = [];
  const manifests = [];
  for (const file of files) {
    const path = file.filename;
    if (LOCKFILE.test(path)) {
      lockfiles += 1;
      continue;
    }
    const asset = ASSET.test(path);
    const generated = GENERATED.test(path);
    if (!asset && !generated) lines += (file.additions ?? 0) + (file.deletions ?? 0);
    if (rules.area.test(path) && !rules.notUi.test(path) && (UI_SOURCE.test(path) || asset) && !TEST.test(path)) ui.push(path);
    if (DOC.test(path) || TEST.test(path) || asset || generated) continue;
    if (MANIFEST.test(path)) manifests.push(file);
    else code += 1;
  }
  const typesOnlyManifests = manifests.length > 0 && manifests.every((file) => changesOnlyTypesPackages(file.patch));
  // A dependency change is behavior unless every manifest edit is an `@types/*`
  // package; a lockfile on its own (lock maintenance) moves runtime versions too.
  const behavior = code > 0 || (manifests.length > 0 && !typesOnlyManifests) || (lockfiles > 0 && !typesOnlyManifests);
  return { lines, ui, behavior };
}

/** True when every changed line of a package.json patch names an `@types/*` package. */
export function changesOnlyTypesPackages(patch) {
  if (typeof patch !== 'string' || patch.length === 0) return false;
  const changed = patch
    .split('\n')
    .filter((line) => /^[+-]/.test(line) && !/^(\+\+\+|---)/.test(line))
    .map((line) => line.slice(1).trim())
    .filter((line) => line.length > 0);
  return changed.length > 0 && changed.every((line) => /^"@types\/[^"]+"\s*:/.test(line));
}

export function sizeLabel(lines) {
  return SIZES.find((size) => lines < size.below).name;
}

// Images that bots and services put in PR threads (deploy cards, badges, coverage, avatars).
const SERVICE_MEDIA = /vercel\.com|netlify\.(com|app)|shields\.io|badge|codecov\.io|coveralls\.io|renovate|mend\.io|avatars\.githubusercontent\.com|githubusercontent\.com\/u\//i;
const MEDIA_PATTERNS = [
  /!\[[^\]]*\]\(\s*<?([^)\s>]+)>?(?:\s+"[^"]*")?\s*\)/g,
  /<(?:img|video|source)\b[^>]*\bsrc\s*=\s*["']([^"']+)["']/gi,
  /(https:\/\/github\.com\/user-attachments\/assets\/[A-Za-z0-9-]+)/g,
  /(https?:\/\/[^\s)<>"']+\.(?:png|jpe?g|gif|webp|mp4|mov|webm)(?:\?[^\s)<>"']*)?)/gi,
  /(https?:\/\/(?:www\.)?loom\.com\/share\/[^\s)<>"']+)/gi,
];
const URL_PATTERN = /https?:\/\/[^\s)<>"'`]+/g;
const FENCED_BLOCK = /```[^\n]*\n([\s\S]*?)```/g;
const EVIDENCE_HEADING = /^(#{2,4})\s*(evidence|proof)\b.*$/im;

export function stripComments(text) {
  return (text ?? '').replace(/<!--[\s\S]*?-->/g, '');
}

/** Media URLs a person attached (service images such as deploy cards are ignored). */
export function findMedia(text) {
  const found = new Set();
  const clean = stripComments(text);
  for (const regex of MEDIA_PATTERNS) {
    for (const match of clean.matchAll(regex)) {
      const url = match[1];
      if (url && !SERVICE_MEDIA.test(url)) found.add(url);
    }
  }
  return [...found];
}

/** The body of a `## Evidence` or `## Proof` section, up to the next heading of the same or higher level. */
export function evidenceSection(text) {
  const clean = stripComments(text);
  const heading = clean.match(EVIDENCE_HEADING);
  if (!heading) return '';
  const level = heading[1].length;
  const rest = clean.slice(heading.index + heading[0].length);
  const next = rest.search(new RegExp(`^#{1,${level}}\\s`, 'm'));
  return next === -1 ? rest : rest.slice(0, next);
}

/** Evidence of a real run: output in a code block, a recording or screenshot, or a link. Prose alone is not. */
export function hasRunEvidence(section) {
  if (!section.trim()) return false;
  for (const match of section.matchAll(FENCED_BLOCK)) {
    if (match[1].trim()) return true;
  }
  if (findMedia(section).length > 0) return true;
  return [...section.matchAll(URL_PATTERN)].some((match) => !SERVICE_MEDIA.test(match[0]));
}

const TRUSTED_ASSOCIATIONS = new Set(['OWNER', 'MEMBER', 'COLLABORATOR']);

/**
 * Evidence across the PR body and the comments and reviews written by people
 * (the PR author or a collaborator, never a bot account).
 */
export function collectEvidence({ pr, comments = [], reviews = [] }) {
  const human = (entry) => entry.user?.type !== 'Bot'
    && (entry.user?.login === pr.user?.login || TRUSTED_ASSOCIATIONS.has(entry.author_association));
  const notes = [...comments, ...reviews].filter(human).map((entry) => entry.body ?? '');
  const media = new Set(findMedia(pr.body));
  for (const note of notes) for (const url of findMedia(note)) media.add(url);
  const sections = [evidenceSection(pr.body)];
  for (const note of notes) {
    const section = evidenceSection(note);
    if (section) sections.push(section);
    else if (/^\s*(\*\*)?(evidence|proof)\b/i.test(stripComments(note))) sections.push(stripComments(note));
  }
  return { media: media.size, run: sections.some(hasRunEvidence) };
}

// GitHub resolves label names case-insensitively (a PR's `size/s` is the
// repository's `size/S` label, under the name it was created with), so every
// comparison of label names goes through this.
const key = (name) => name.toLowerCase();

/** The proof labels a PR should carry, or null when a maintainer override is on. */
export function decideProof({ classification, evidence, labels }) {
  if (labels.some((label) => key(label) === key(PROOF.override))) return null;
  const { ui, behavior } = classification;
  if (ui.length === 0 && !behavior) return [PROOF.notNeeded];
  const needs = [];
  if (ui.length > 0 && evidence.media === 0) needs.push(PROOF.screenshots);
  if (behavior && !evidence.run) needs.push(PROOF.e2e);
  return needs.length > 0 ? needs : [PROOF.sufficient];
}

const OWNED_PROOF = new Set([PROOF.sufficient, PROOF.screenshots, PROOF.e2e, PROOF.notNeeded].map(key));

/**
 * Label changes, limited to the families this script owns. `proof` null leaves
 * proof labels alone. Names match in any case: a label already on the PR in
 * another case is neither added again nor removed, and one to remove is
 * removed under the name the PR has.
 */
export function planLabels(current, { size, proof }) {
  const add = new Set();
  const remove = new Set();
  const have = new Set(current.map(key));
  for (const label of current) {
    if (key(label).startsWith('size/') && key(label) !== key(size)) remove.add(label);
  }
  if (!have.has(key(size))) add.add(size);
  if (proof) {
    const wanted = new Set(proof.map(key));
    for (const label of current) {
      if (OWNED_PROOF.has(key(label)) && !wanted.has(key(label))) remove.add(label);
    }
    for (const label of proof) if (!have.has(key(label))) add.add(label);
  }
  return { add: [...add].sort(), remove: [...remove].sort() };
}

// ---------------------------------------------------------------------------
// GitHub I/O. Everything above is pure.
// ---------------------------------------------------------------------------

function parseArgs(argv) {
  const args = { dryRun: false };
  for (let i = 0; i < argv.length; i += 1) {
    if (argv[i] === '--dry-run') args.dryRun = true;
    else if (argv[i] === '--repo') args.repo = argv[++i];
    else if (argv[i] === '--pr') args.pr = Number(argv[++i]);
  }
  return args;
}

function client(token) {
  const api = (process.env.GITHUB_API_URL || 'https://api.github.com').replace(/\/$/, '');
  const request = async (method, path, body) => {
    const url = path.startsWith('https://') ? path : `${api}${path}`;
    const response = await fetch(url, {
      method,
      headers: {
        Accept: 'application/vnd.github+json',
        Authorization: `Bearer ${token}`,
        'X-GitHub-Api-Version': '2022-11-28',
        ...(body ? { 'Content-Type': 'application/json' } : {}),
      },
      body: body ? JSON.stringify(body) : undefined,
    });
    if (!response.ok) {
      const detail = (await response.text()).slice(0, 300);
      const error = new Error(`${method} ${path} -> ${response.status}: ${detail}`);
      error.status = response.status;
      throw error;
    }
    return { data: response.status === 204 ? null : await response.json(), link: response.headers.get('link') };
  };
  const paginate = async (path) => {
    const items = [];
    let next = path;
    while (next) {
      const { data, link } = await request('GET', next);
      items.push(...data);
      next = link?.match(/<([^>]+)>;\s*rel="next"/)?.[1] ?? null;
    }
    return items;
  };
  return { request, paginate };
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const token = process.env.GITHUB_TOKEN;
  if (!token) throw new Error('GITHUB_TOKEN is not set');
  const rules = uiRules();
  const repo = args.repo ?? process.env.GITHUB_REPOSITORY;
  let number = args.pr;
  if (!number && process.env.GITHUB_EVENT_PATH) {
    const event = JSON.parse(readFileSync(process.env.GITHUB_EVENT_PATH, 'utf8'));
    number = event.pull_request?.number ?? (event.issue?.pull_request ? event.issue.number : undefined);
  }
  if (!repo || !number) throw new Error('need a repository and a PR number (--repo owner/name --pr N)');

  const gh = client(token);
  const { data: pr } = await gh.request('GET', `/repos/${repo}/pulls/${number}`);
  if (pr.state !== 'open') {
    console.log(`PR #${number} is ${pr.state}; nothing to do.`);
    return;
  }
  const [files, comments, reviews] = await Promise.all([
    gh.paginate(`/repos/${repo}/pulls/${number}/files?per_page=100`),
    gh.paginate(`/repos/${repo}/issues/${number}/comments?per_page=100`),
    gh.paginate(`/repos/${repo}/pulls/${number}/reviews?per_page=100`),
  ]);
  const labels = pr.labels.map((label) => label.name);
  const classification = classifyFiles(files, rules);
  const evidence = collectEvidence({ pr, comments, reviews });
  const size = sizeLabel(classification.lines);
  const proof = decideProof({ classification, evidence, labels });
  const { add, remove } = planLabels(labels, { size, proof });

  const report = [
    `### PR labels for #${number}`,
    `- ${classification.lines} lines changed (lockfiles, generated files and assets not counted): \`${size}\``,
    `- UI files: ${classification.ui.length}${classification.ui.length ? ` (${classification.ui.slice(0, 5).join(', ')}${classification.ui.length > 5 ? ', ...' : ''})` : ''}; behavior change: ${classification.behavior}`,
    `- Evidence: ${evidence.media} screenshot or recording link(s); run evidence in an Evidence section: ${evidence.run}`,
    proof ? `- Proof: ${proof.map((label) => `\`${label}\``).join(', ')}` : `- Proof: left alone (\`${PROOF.override}\` is on)`,
    `- Add: ${add.length ? add.map((l) => `\`${l}\``).join(', ') : 'none'}; remove: ${remove.length ? remove.map((l) => `\`${l}\``).join(', ') : 'none'}`,
  ].join('\n');
  console.log(report);
  if (process.env.GITHUB_STEP_SUMMARY) appendFileSync(process.env.GITHUB_STEP_SUMMARY, `${report}\n`);
  if (args.dryRun || (add.length === 0 && remove.length === 0)) return;

  try {
    const existing = new Set((await gh.paginate(`/repos/${repo}/labels?per_page=100`)).map((label) => key(label.name)));
    for (const definition of LABEL_DEFINITIONS) {
      if (add.includes(definition.name) && !existing.has(key(definition.name))) {
        await gh.request('POST', `/repos/${repo}/labels`, definition);
      }
    }
    if (add.length > 0) await gh.request('POST', `/repos/${repo}/issues/${number}/labels`, { labels: add });
    for (const label of remove) {
      try {
        await gh.request('DELETE', `/repos/${repo}/issues/${number}/labels/${encodeURIComponent(label)}`);
      } catch (error) {
        if (error.status !== 404) throw error; // already gone
      }
    }
  } catch (error) {
    // A fork PR gets a read-only token and cannot write labels; say so without
    // failing it. Anywhere else a 403 is a real misconfiguration, so it fails.
    const fromFork = pr.head?.repo?.full_name !== repo;
    if (error.status === 403 && fromFork) {
      console.log(`::warning::could not update labels on fork PR #${number}: ${error.message}`);
      return;
    }
    throw error;
  }
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? '').href) {
  main().catch((error) => {
    console.error(error.message);
    process.exit(1);
  });
}
