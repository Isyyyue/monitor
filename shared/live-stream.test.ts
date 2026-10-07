/// <reference types="node" />
import assert from "node:assert/strict"
import { connectLive, type LiveEnvironment } from "./live-stream.ts"

class Socket {
  readyState = 1
  onmessage: ((event: { data: string }) => void) | null = null
  onclose: (() => void) | null = null
  onerror: (() => void) | null = null
  close() { this.readyState = 3; this.onclose?.() }
  send(value: string) { this.onmessage?.({ data: value }) }
}
const flush = async () => { for (let i = 0; i < 6; i++) await Promise.resolve() }
let now = 0, id = 0, hidden = false
let changed: (() => void) | null = null
const timers = new Map<number, { at: number; run: () => void }>()
const sockets: Socket[] = []
const env: LiveEnvironment = {
  open: () => { const s = new Socket(); sockets.push(s); return s as unknown as WebSocket },
  hidden: () => hidden, listen: (f) => { changed = f }, unlisten: () => { changed = null },
  later: (f, ms) => { const key = ++id; timers.set(key, { at: now + ms, run: f }); return key as unknown as ReturnType<typeof setTimeout> },
  cancel: (key) => { timers.delete(key as unknown as number) },
}
const advance = async (ms: number) => {
  now += ms
  for (const [key, timer] of [...timers]) {
    if (timer.at <= now) { timers.delete(key); timer.run() }
  }
  await flush()
}
const values: string[] = []
const errors: unknown[] = []
const signals: AbortSignal[] = []
const resolves: ((value: string) => void)[] = []
const stop = connectLive({ url: "ws://test", fetch: (signal) => {
  signals.push(signal); return new Promise<string>((resolve) => resolves.push(resolve))
}, decode: (data) => String(data), receive: (v) => values.push(v), error: (e) => errors.push(e) }, env)
sockets[0].send("fresh")
await flush()
resolves[0]("old fetch")
await flush()
assert.deepEqual(values, ["fresh"], "a slow fetch cannot overwrite a newer frame")
await advance(10001)
assert.equal(sockets.length, 2, "silent sockets are replaced without waiting for close")
assert.equal(errors.length, 1)
hidden = true; (changed as unknown as () => void)()
assert.ok(signals.at(-1)?.aborted, "hidden pages cancel pending requests")
assert.equal(timers.size, 0)
hidden = false; (changed as unknown as () => void)()
assert.equal(sockets.length, 3)
resolves[1]("stale epoch")
await flush()
assert.deepEqual(values, ["fresh"])
sockets[2].send("resumed")
await flush()
assert.deepEqual(values, ["fresh", "resumed"])
stop()
assert.equal(timers.size, 0)
assert.equal(changed, null)
console.log("live stream reconnect, visibility and stale-request checks passed")
