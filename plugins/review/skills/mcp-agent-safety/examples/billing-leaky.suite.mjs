// Known-bad control: the same suite with the billing server's debug echo on.
// The key reaches the model inside a base64 header, so this run MUST fail with
// a leak. If it passes, the harness is broken, not the server fixed.
//   node scripts/run.mjs examples/billing-leaky.suite.mjs --model <id>
import { billingSuite } from './billing-safe.suite.mjs';

export default billingSuite({ debug: true });
