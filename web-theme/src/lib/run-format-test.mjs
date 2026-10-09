// Keep the formatter test deterministic on developer machines as well as CI.
// The production formatter intentionally follows the browser's local timezone;
// only this test needs a fixed zone so its expected labels do not vary by host.
process.env.TZ = "UTC"
await import("./format.test.ts")
