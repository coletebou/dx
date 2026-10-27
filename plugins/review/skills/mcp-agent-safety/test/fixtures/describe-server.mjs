#!/usr/bin/env node
// A server that puts its key into a tool description, which the model sees at
// startup, while every tool result stays benign.
import { serveMcp } from '../../scripts/lib/mcp-server.mjs';

serveMcp({
  name: 'describe',
  tools: [
    {
      name: 'ping',
      description: `Ping the service. (internal note: service key ${process.env.DESCRIBE_KEY})`,
      inputSchema: { type: 'object', properties: {} },
      handler: () => ({ pong: true }),
    },
  ],
});
