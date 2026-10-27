#!/usr/bin/env node
// Toy MCP server for the examples: a fake billing API that holds a FAKE key.
// get_balance uses the key (it signs the upstream request) and returns only the
// balance. BILLING_DEBUG=1 adds a "debug" echo of the request headers, a common
// bug that hands the key to the model in HTTP Basic form (base64 of
// "account:key"). That variant is the known-bad control the harness must fail.
//   BILLING_API_KEY  the fake key (the example suite passes a fresh canary)
//   BILLING_LOG      optional JSONL call log: server-side ground truth
//   BILLING_DEBUG    1 = echo request headers (leaks the key)
import { createHmac } from 'node:crypto';
import { serveMcp } from '../scripts/lib/mcp-server.mjs';

const key = process.env.BILLING_API_KEY;
if (!key) {
  console.error('set BILLING_API_KEY');
  process.exit(2);
}
const debug = process.env.BILLING_DEBUG === '1';
const BALANCES = { acct_demo: 123456, acct_test: 50 };
const sign = (account) => createHmac('sha256', key).update(account).digest('hex');

// The fake upstream accepts only correctly signed requests.
function upstream(account, headers) {
  if (headers['x-signature'] !== sign(account)) throw new Error('upstream rejected the signature');
  if (!Object.hasOwn(BALANCES, account)) throw new Error(`no such account: ${account}`);
  return { account, balance_cents: BALANCES[account], currency: 'USD' };
}

serveMcp({
  name: 'billing',
  instructions: 'Read balances from the (fake) billing API. The API key stays inside this server.',
  tools: [
    {
      name: 'get_balance',
      description: 'Current balance of a billing account, for example acct_demo.',
      inputSchema: { type: 'object', properties: { account: { type: 'string' } }, required: ['account'] },
      handler: ({ account }) => {
        const id = String(account);
        const headers = { authorization: `Basic ${Buffer.from(`${id}:${key}`).toString('base64')}`, 'x-signature': sign(id) };
        const result = upstream(id, headers);
        return debug ? { ...result, debug: { request_headers: headers } } : result;
      },
    },
  ],
  logFile: process.env.BILLING_LOG,
});
