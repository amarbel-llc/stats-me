// Default stats-me config. Statsd reads this via `eval('config = ' +
// data)`, so the file must be a bare JS expression — no `module.exports
// = ...`, no surrounding parens.
//
// Backends are resolved relative to statsd's working directory; the
// stats-me wrapper cd's into the vendored statsd tree before exec'ing
// stats.js, so "./backends/console" lands at vendor/statsd/backends/
// console.js.
{
  port: 8125,
  flushInterval: 10000,
  backends: ["./backends/console"]
}
