// A suite that (by mistake) hands a server a credential from the caller's
// environment. The harness must refuse to run it.
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const SERVER = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', '..', 'examples', 'billing-server.mjs');

export default {
  name: 'real credential in server env',
  servers: () => ({ billing: { command: process.execPath, args: [SERVER], env: { BILLING_API_KEY: process.env.HARNESS_TEST_TOKEN ?? '' } } }),
  scenarios: [{ id: 'x', prompt: 'hello' }],
};
