/** Browser transport shared by the admin and public pages. No React state. */
type Timer = ReturnType<typeof setTimeout>
export type LiveEnvironment = {
  open: (url: string) => WebSocket
  hidden: () => boolean
  listen: (callback: () => void) => void
  unlisten: (callback: () => void) => void
  later: (callback: () => void, milliseconds: number) => Timer
  cancel: (timer: Timer) => void
}

export function connectLive<T>(options: {
  url: string
  fetch: (signal: AbortSignal) => Promise<T>
  decode: (data: unknown) => T | Promise<T>
  receive: (value: T) => void
  error: (error: unknown) => void
  gap?: () => void
}, supplied?: LiveEnvironment): () => void {
  const env: LiveEnvironment = supplied ?? {
    open: (url) => new WebSocket(url), hidden: () => document.hidden,
    listen: (f) => document.addEventListener("visibilitychange", f),
    unlisten: (f) => document.removeEventListener("visibilitychange", f),
    later: (f, ms) => setTimeout(f, ms), cancel: (timer) => clearTimeout(timer),
  }
  let socket: WebSocket | null = null
  let retry: Timer | null = null
  let watchdog: Timer | null = null
  let poll: Timer | null = null
  let fetchController: AbortController | null = null
  let epoch = 0
  let received = 0
  let stopped = false
  const clear = (timer: Timer | null) => { if (timer !== null) env.cancel(timer) }
  const fetchOnce = async () => {
    if (stopped || env.hidden() || fetchController) return
    const controller = new AbortController()
    fetchController = controller
    const began = epoch
    const sequence = received
    try {
      const value = await options.fetch(controller.signal)
      if (!stopped && began === epoch && sequence === received) { received++; options.receive(value) }
    } catch (error) {
      if (!stopped && began === epoch && sequence === received && !controller.signal.aborted) options.error(error)
    } finally {
      if (fetchController === controller) fetchController = null
    }
  }
  const pollLater = () => {
    if (poll !== null || stopped || env.hidden()) return
    poll = env.later(() => { poll = null; void fetchOnce(); pollLater() }, 5000)
  }
  const pause = () => {
    epoch++
    fetchController?.abort(); fetchController = null
    if (socket) { socket.onclose = socket.onmessage = socket.onerror = null; socket.close(); socket = null }
    clear(retry); clear(watchdog); clear(poll)
    retry = watchdog = poll = null
  }
  const connect = () => {
    if (stopped || env.hidden()) return
    let opened: WebSocket
    try { opened = env.open(options.url) }
    catch { pollLater(); retry = env.later(connect, 5000); return }
    socket = opened
    const began = epoch
    const watch = () => {
      clear(watchdog)
      watchdog = env.later(() => {
        options.error(new Error("实时数据中断，正在重新连接"))
        resume()
      }, 10000)
    }
    watch()
    let pending = Promise.resolve()
    opened.onmessage = (event) => {
      pending = pending.then(async () => {
        const value = await options.decode(event.data)
        if (stopped || began !== epoch || opened !== socket) return
        received++; watch(); options.receive(value)
        clear(poll); poll = null
      }).catch((error) => { if (!stopped && began === epoch) options.error(error) })
    }
    opened.onerror = () => opened.close()
    opened.onclose = () => {
      if (stopped || began !== epoch || socket !== opened) return
      socket = null; clear(watchdog); watchdog = null
      pollLater(); retry = env.later(connect, 5000)
    }
  }
  const resume = () => {
    pause()
    if (stopped || env.hidden()) return
    options.gap?.(); void fetchOnce(); connect()
  }
  const visibility = () => { if (env.hidden()) pause(); else resume() }
  env.listen(visibility)
  resume()
  return () => { stopped = true; env.unlisten(visibility); pause() }
}
