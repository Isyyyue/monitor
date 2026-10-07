import assert from "node:assert/strict"
import { installScriptCommand } from "./install-command.ts"

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
console.log("install command certificate policy passed")
