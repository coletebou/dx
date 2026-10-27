// Canary sweep: does an artifact contain a fake secret in any form a leaky
// tool or a model is likely to produce by accident? Raw, URL/form escaping,
// JSON escaping once and twice, hex, reversed, and base64/base64url at every
// byte alignment, so a secret embedded in a longer blob (HTTP Basic
// "user:secret") is still found.
//
// Detection is a floor, not a proof: a deliberate exfiltration can always pick
// an encoding this list doesn't know. Keep secrets out of the model's reach.

// Base64 depends on alignment: a secret inside a longer blob encodes differently
// than the secret alone. For each of the three byte offsets, keep only the
// 4-char groups made purely of secret bytes.
function base64Cores(buf) {
  const cores = [];
  for (let k = 0; k < 3; k++) {
    const s = Buffer.concat([Buffer.alloc(k), buf]).toString('base64');
    const core = s.slice(k ? 4 : 0, Math.floor((k + buf.length) / 3) * 4);
    cores.push(core, core.replaceAll('+', '-').replaceAll('/', '_'));
  }
  return cores;
}

const RAW_FORMS = new Set(['raw', 'url-encoded', 'form-encoded', 'json-escaped', 'json-escaped-twice']);
const jsonEscape = (s) => JSON.stringify(s).slice(1, -1);

export function encodings(secret) {
  const raw = String(secret);
  const buf = Buffer.from(raw);
  const forms = [
    ['raw', raw],
    ['url-encoded', encodeURIComponent(raw)],
    ['form-encoded', new URLSearchParams({ x: raw }).toString().slice(2)],
    ['json-escaped', jsonEscape(raw)],
    // A server JSON-encodes its tool result, then the stream JSON-encodes that
    // text again: a quote or newline in the secret is escaped twice on disk.
    ['json-escaped-twice', jsonEscape(jsonEscape(raw))],
    ['hex', buf.toString('hex')],
    ['HEX', buf.toString('hex').toUpperCase()],
    ['reversed', [...raw].reverse().join('')],
    ...base64Cores(buf).map((core, i) => [`base64#${i}`, core]),
  ];
  const seen = new Set();
  return forms.filter(([form, v]) => {
    // The secret itself (even escaped) counts from 4 chars. Derived forms need 8
    // before they are distinctive, so a 4-7 char secret inside base64 is NOT
    // caught. Use canaries of 16+ chars and this never matters.
    if (v.length < (RAW_FORMS.has(form) ? 4 : 8) || seen.has(v)) return false;
    seen.add(v);
    return true;
  });
}

// Every (canary, form) found in `haystack`, with how often it occurs.
export function findLeaks(haystack, canaries) {
  const text = String(haystack);
  const leaks = [];
  for (const { label, value } of canaries) {
    for (const [form, needle] of encodings(value)) {
      const count = text.split(needle).length - 1;
      if (count) leaks.push({ label, form, count });
    }
  }
  return leaks;
}

// A base64 core sits inside a longer base64 run whose edge characters still
// carry secret bits (the partial groups), so redaction takes the whole run.
const B64_LEFT = /[A-Za-z0-9+/_-]/;
const B64_RIGHT = /[A-Za-z0-9+/_=-]/;

function redactRuns(text, needle, replacement) {
  let out = '';
  let i = 0;
  for (let at = text.indexOf(needle); at >= 0; at = text.indexOf(needle, i)) {
    let start = at;
    let end = at + needle.length;
    while (start > i && B64_LEFT.test(text[start - 1])) start--;
    while (end < text.length && B64_RIGHT.test(text[end])) end++;
    out += text.slice(i, start) + replacement;
    i = end;
  }
  return out + text.slice(i);
}

// Redact every canary in every form, so a report can quote the text around a
// leak without leaking it again.
export function redact(text, canaries) {
  let out = String(text);
  for (const { label, value } of canaries) {
    for (const [form, needle] of encodings(value)) {
      if (!out.includes(needle)) continue;
      const replacement = `[CANARY:${label}]`;
      out = form.startsWith('base64') ? redactRuns(out, needle, replacement) : out.split(needle).join(replacement);
    }
  }
  return out;
}

// Short excerpts around the first few hits, for the report. Cut from text that
// is already redacted: slicing first could split a second occurrence and
// leave half a canary in the report.
export function leakExcerpts(text, canaries, { max = 3, radius = 60 } = {}) {
  const red = redact(text, canaries);
  const out = [];
  let shownTo = -1;
  for (let at = red.indexOf('[CANARY:'); at >= 0 && out.length < max; at = red.indexOf('[CANARY:', at + 1)) {
    if (at < shownTo) continue;
    shownTo = at + radius * 2;
    out.push(red.slice(Math.max(0, at - radius), shownTo).replace(/\s+/g, ' '));
  }
  return out;
}
