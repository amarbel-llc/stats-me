// Reproduce statsd's actual dgram usage pattern in isolation.
// Mirrors stats.js as of statsd 0.10.2:
//
//   var server = dgram.createSocket(serverConfig);
//   server.on('message', onMessage);
//   server.bind(config.port || 8125, config.address || undefined);
//
// The interesting bits:
//  - createSocket called with an OBJECT, not a string (statsd passes
//    `{type: "udp4", reuseAddr: undefined}` derived from config)
//  - bind called with `address: undefined` when statsd's config has
//    no `address` field (which our POC config didn't)
//  - statsd registers 'message' BEFORE 'listening', then bind()
//
// If this reproducer drops packets the same way statsd does, we have
// a Bun-specific bug in one of those three corners. If it works, the
// problem is somewhere else in statsd we haven't read yet.

const dgram = require("dgram");

const PORT = 18125;

// Match statsd's createSocket pattern: object form, with reuseAddr
// undefined (because we didn't set it in config).
const serverConfig = { type: "udp4", reuseAddr: undefined };
const server = dgram.createSocket(serverConfig);

server.on("message", (buf, rinfo) => {
  console.log(`got ${buf.length}B from ${rinfo.address}:${rinfo.port}: ${buf.toString().trimEnd()}`);
});

server.on("listening", () => {
  const a = server.address();
  console.log(`listening on ${a.address}:${a.port}`);
});

server.on("error", (err) => {
  console.error("err:", err);
  process.exit(1);
});

// Match statsd's bind: pass `undefined` for address explicitly.
server.bind(PORT, undefined);
