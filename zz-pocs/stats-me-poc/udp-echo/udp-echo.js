// Minimal UDP echo server. Same code runs under bun or node — the
// only difference is the runtime. Listens on 127.0.0.1:18125 and
// prints every packet it receives.
//
// Run:  bun udp-echo.js   OR   node udp-echo.js
// Then in another shell: echo 'hello' | nc -u -w0 127.0.0.1 18125
const dgram = require("dgram");

const PORT = 18125;
const HOST = "127.0.0.1";

const sock = dgram.createSocket("udp4");

sock.on("listening", () => {
  const a = sock.address();
  console.log(`listening on ${a.address}:${a.port}`);
});

sock.on("message", (buf, rinfo) => {
  console.log(`got ${buf.length}B from ${rinfo.address}:${rinfo.port}: ${buf.toString().trimEnd()}`);
});

sock.on("error", (err) => {
  console.error("err:", err);
  process.exit(1);
});

sock.bind(PORT, HOST);
