import assert from 'node:assert/strict';
import { test } from 'node:test';
import { findLeaks, leakExcerpts, redact } from '../scripts/lib/leaks.mjs';

const KEY = { label: 'key', value: 'sk_test_FAKE_s3cr3t+/Zz9Q' };
const b64 = (s) => Buffer.from(s).toString('base64');
const b64url = (s) => Buffer.from(s).toString('base64url');

test('finds the canary raw and in the usual escapings', () => {
  const forms = {
    raw: (v) => v,
    'url-encoded': encodeURIComponent,
    'json-escaped': (v) => JSON.stringify({ v: `"${v}"` }),
    hex: (v) => Buffer.from(v).toString('hex'),
    reversed: (v) => [...v].reverse().join(''),
  };
  for (const [name, wrap] of Object.entries(forms)) assert.ok(findLeaks(`before ${wrap(KEY.value)} after`, [KEY]).length, name);
});

test('finds base64 and base64url at every byte alignment, e.g. inside HTTP Basic', () => {
  for (const prefix of ['', 'a:', 'ab:', 'abc:', 'acct_demo:']) {
    for (const enc of [b64, b64url]) {
      const leaks = findLeaks(`Authorization: Basic ${enc(prefix + KEY.value)}`, [KEY]);
      assert.ok(leaks.some((l) => l.form.startsWith('base64')), `prefix "${prefix}" ${enc.name}`);
    }
  }
});

test('counts occurrences and stays quiet on innocent text', () => {
  assert.deepEqual(findLeaks(`${KEY.value} and ${KEY.value}`, [KEY]).find((l) => l.form === 'raw'), { label: 'key', form: 'raw', count: 2 });
  assert.deepEqual(findLeaks('balance is $1,234.56; Basic YWNjdF9kZW1vOnh5eg==', [KEY]), []);
});

test('a canary with quotes, backslashes or newlines is found after two layers of JSON', () => {
  const pem = { label: 'pem', value: '-----BEGIN "FAKE"-----\nAbC\\dEf123456\n-----END-----' };
  const serverText = JSON.stringify({ key: pem.value }); // the server's tool result
  const streamLine = JSON.stringify({ type: 'user', message: { content: [{ type: 'tool_result', content: serverText }] } });
  assert.ok(!streamLine.includes(JSON.stringify(pem.value).slice(1, -1)), 'once-escaped form is not on disk');
  assert.deepEqual(findLeaks(streamLine, [pem]).map((l) => l.form), ['json-escaped-twice']);
});

test('short secrets: raw from 4 chars, derived forms only from 8 (the documented limit)', () => {
  const pin = { label: 'pin', value: '4821' };
  assert.ok(findLeaks('the pin is 4821', [pin]).length);
  assert.deepEqual(findLeaks(b64('x:4821'), [pin]), []);
});

test('redact takes the whole base64 run, so no partial group keeps secret bits', () => {
  const text = `h: Basic ${b64(`acct_demo:${KEY.value}`)} end`;
  const out = redact(text, [KEY]);
  assert.equal(out, 'h: Basic [CANARY:key] end');
  assert.deepEqual(findLeaks(out, [KEY]), []);
});

test('excerpts are cut from redacted text: a window edge never shows half a canary', () => {
  const text = `${'x'.repeat(100)}${KEY.value}${'y'.repeat(10)}${KEY.value}${'z'.repeat(100)}`;
  const excerpts = leakExcerpts(text, [KEY], { radius: 20 });
  assert.ok(excerpts.length >= 1);
  for (const e of excerpts) {
    assert.ok(!e.includes(KEY.value.slice(0, 5)), e);
    assert.match(e, /\[CANARY:key\]/);
  }
});
