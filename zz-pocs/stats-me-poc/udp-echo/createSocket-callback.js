// Test the exact dgram pattern statsd uses in servers/udp.js:
// the createSocket(type, callback) shorthand for registering a
// 'message' listener.
//
// Per Node docs:
//   dgram.createSocket(type, callback)
//     The callback is automatically added as a listener for the
//     'message' event.
//
// If Bun doesn't honor the callback-arg shorthand, that's the bug.

const dgram = require("dgram");

const PORT = 18125;

const onMessage = (buf, rinfo) => {
  console.log(`got ${buf.length}B from ${rinfo.address}:${rinfo.port}: ${buf.toString().trimEnd()}`);
};

// THIS is the line statsd uses. The callback should auto-register
// as a 'message' listener.
const server = dgram.createSocket("udp4", onMessage);

server.on("listening", () => {
  const a = server.address();
  console.log(`listening on ${a.address}:${a.port}`);
});

server.on("error", (err) => {
  console.error("err:", err);
  process.exit(1);
});

server.bind(PORT, undefined);
