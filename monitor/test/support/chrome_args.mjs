// CI-only extra Chrome flags (e.g. --no-sandbox on root runners), gated to an
// explicit env knob so local runs never carry them (adjudicated in #397).
// Shared by every TEST harness — the #337 bench gate deliberately does NOT
// import this (its artifact is sealed). Values are split on whitespace:
// quoted or space-bearing flags are NOT supported by design; the knob carries
// discrete tokens only (CI sets "--no-sandbox --disable-dev-shm-usage").
export function extraBrowserArgs() {
  return (process.env.PIXIR_MONITOR_BROWSER_EXTRA_ARGS || "").split(/\s+/).filter(Boolean);
}
