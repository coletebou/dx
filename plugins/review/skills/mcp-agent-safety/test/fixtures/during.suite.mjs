// The `during` hook sees the live session: it waits for the first tool call,
// then records what the chat said after its mark.
import { billingSuite } from '../../examples/billing-safe.suite.mjs';

const base = billingSuite();
let seen = null;

export default {
  ...base,
  name: 'during hook',
  scenarios: [
    {
      ...base.scenarios[0],
      // Keep ctx whole: destructuring would freeze the `stopped` getter.
      during: async (ctx) => {
        const mark = ctx.chat.mark();
        while (!ctx.stopped && !ctx.session.toolCalls.length) await ctx.sleep(20);
        seen = { calls: ctx.session.toolCalls.length, since: ctx.chat.since(mark) };
      },
      expect: () => [[seen?.calls === 1 && seen.since.includes('Checking.'), `during() saw the live session (${JSON.stringify(seen)})`]],
    },
  ],
};
