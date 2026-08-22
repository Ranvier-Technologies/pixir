// CI-only extra Chrome flags (e.g. --no-sandbox on root runners), gated to an
// explicit env knob so local runs never carry them (adjudicated in #397).
// Shared by every TEST harness — the #337 bench gate deliberately does NOT
// import this (its artifact is sealed). Values are split on whitespace:
// quoted or space-bearing flags are NOT supported by design; the knob carries
// discrete tokens only (CI sets "--no-sandbox --disable-dev-shm-usage").
export function extraBrowserArgs() {
  return (process.env.PIXIR_MONITOR_BROWSER_EXTRA_ARGS || "").split(/\s+/).filter(Boolean);
}

// Per-run tmp prefix for Chrome user-data dirs. ExUnit sets PIXIR_MONITOR_TEST_RUN
// so two concurrent suites cannot glob or delete each other's profiles (#555).
// A standalone/manual harness invocation still gets a process-unique fallback.
export function testRunPrefix(family) {
  const run = process.env.PIXIR_MONITOR_TEST_RUN;
  const token = typeof run === "string" && /^[a-z0-9][a-z0-9-]{0,62}$/.test(run) ? run : `solo-${process.pid}`;
  return `${family}-${token}-`;
}
