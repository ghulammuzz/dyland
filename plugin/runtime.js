import { createWriter, createState, eventTypes, applyEvent, payload, reconcilePending, seconds, sessionRecord } from "./bridge.js"

// V2.1.1 exposes permission.list in plugin context, but no form.list.
// Use only the already-running, same-process managed service for form snapshots.
// This is an outbound OpenCode API read, never a Dyland HTTP listener.
async function formReader(ctx, signal) {
  if (ctx.session.form?.list) return (sessionID) => ctx.session.form.list({ sessionID }, { signal })
  const { Service } = await import("@opencode/client/service")
  const endpoint = await Service.discover({ version: "2.1.1" })
  if (!endpoint || signal.aborted) return undefined
  const url = new URL(endpoint.url)
  if (!["http:", "https:"].includes(url.protocol) ||
      !["127.0.0.1", "localhost", "[::1]"].includes(url.hostname)) return undefined
  const read = async (path) => {
    const response = await fetch(new URL(path, url), {
      headers: Service.headers(endpoint), redirect: "error",
      signal: AbortSignal.any([signal, AbortSignal.timeout(5000)]),
    })
    if (!response.ok) throw new Error("OpenCode snapshot unavailable")
    return response.json()
  }
  if ((await read("/api/info")).pid !== process.pid) return undefined
  return async (sessionID) => {
    const result = await read(`/api/session/${encodeURIComponent(sessionID)}/form`)
    if (!Array.isArray(result.data)) throw new TypeError("Invalid form snapshot")
    return result.data
  }
}

export function startBridge(ctx, { home, heartbeat = 10_000, resync = 20_000 } = {}) {
  const state = createState()
  const writer = createWriter(ctx.location.directory, home)
  const controller = new AbortController()
  const { signal } = controller
  let debounce
  let retryTimer
  let retryResolve
  let syncing = false
  let readingForms
  let forms
  let eventRevision = 0
  const queue = []
  let draining = false
  const requestOptions = () => ({ signal: AbortSignal.any([signal, AbortSignal.timeout(5000)]) })
  const publish = () => { if (!signal.aborted) writer.publish(payload(state)) }
  const schedule = () => {
    if (signal.aborted || debounce) return
    debounce = setTimeout(() => { debounce = undefined; publish() }, 50)
    debounce.unref?.()
  }
  const refresh = async () => {
    if (syncing || signal.aborted) return
    syncing = true
    try {
      const revision = eventRevision
      const records = new Map()
      let cursor
      const cursors = new Set()
      do {
        const page = await ctx.session.list(cursor ? { cursor, limit: 200 - records.size } :
          { parentID: null, limit: 200, order: "desc" }, requestOptions())
        if (!Array.isArray(page?.data)) throw new TypeError("Invalid session page")
        for (const info of page.data) {
          const record = sessionRecord(info)
          if (record) records.set(record.id, record)
          if (records.size >= 200) break
        }
        cursor = page.cursor?.next
        if (!page.data.length || !cursor || cursors.has(cursor)) break
        cursors.add(cursor)
      } while (records.size < 200 && cursors.size < 200 && !signal.aborted)
      if (signal.aborted) return
      // Discard stale snapshots so deleted or moved sessions cannot reappear.
      if (revision !== eventRevision) return
      state.sessions = records
      for (const [id, pending] of state.pending) {
        if (state.sessions.get(pending.sessionID)?.directory !== ctx.location.directory) state.pending.delete(id)
      }
      if (!forms && !readingForms) {
        readingForms = true
        try { forms = await formReader(ctx, signal) } catch { /* Retry next resync. */ }
        finally { readingForms = false }
      }
      // Keep global session metadata, but reconcile requests only for this writer's location.
      const sessions = [...state.sessions.values()]
        .filter((session) => session.directory === ctx.location.directory).map((session) => session.id)
      let index = 0
      await Promise.all(Array.from({ length: Math.min(8, sessions.length) }, async () => {
        while (index < sessions.length && !signal.aborted) {
          const sessionID = sessions[index++]
          const before = eventRevision
          const results = await Promise.allSettled([
            ctx.permission.list({ sessionID }, requestOptions()),
            forms ? forms(sessionID) : Promise.reject(new Error("Form API not exposed")),
          ])
          if (signal.aborted || before !== eventRevision) continue
          results.forEach((result, i) => {
            if (result.status === "fulfilled") reconcilePending(state, sessionID,
              i === 0 ? "permission" : "question", result.value, seconds(Date.now()))
          })
        }
      }))
      schedule()
    } catch { /* Keep last good state; retry on periodic reconciliation. */ }
    finally { syncing = false }
  }
  const handle = async (event) => {
    if (signal.aborted) return
    if (event?.location?.directory && event.location.directory !== ctx.location.directory) return
    const data = event?.data
    const sessionID = event?.type === "form.created" ? data?.form?.sessionID : data?.sessionID
    if (typeof sessionID !== "string" || !sessionID.startsWith("ses")) return
    const known = state.sessions.get(sessionID)
    if (known && known.directory !== ctx.location.directory && event.type !== "session.moved") return
    if (event.type === "session.deleted") {
      if (!known) return
      eventRevision++
      state.sessions.delete(sessionID)
      for (const [id, pending] of state.pending) if (pending.sessionID === sessionID) state.pending.delete(id)
      schedule()
      return
    }
    if (!state.sessions.has(sessionID) || ["session.renamed", "session.moved"].includes(event.type)) {
      try {
        const record = sessionRecord(await ctx.session.get({ sessionID }, requestOptions()))
        if (signal.aborted) return
        if (!record) return
        if (record.directory !== ctx.location.directory) {
          if (known?.directory === ctx.location.directory) {
            eventRevision++
            state.sessions.delete(sessionID)
            for (const [id, pending] of state.pending) if (pending.sessionID === sessionID) state.pending.delete(id)
            schedule()
          }
          return
        }
        if (!state.sessions.has(sessionID) && state.sessions.size >= 200) {
          const oldest = [...state.sessions.values()].reduce((a, b) => a.updatedAt < b.updatedAt ? a : b)
          state.sessions.delete(oldest.id)
        }
        state.sessions.set(sessionID, record)
      } catch { return }
    }
    eventRevision++
    applyEvent(state, event)
    schedule()
  }
  const drain = async () => {
    if (draining) return
    draining = true
    try {
      while (queue.length && !signal.aborted) {
        try { await handle(queue.shift()) } catch { /* Drop malformed events. */ }
      }
    } finally { draining = false }
  }
  const wait = (ms) => new Promise((resolve) => {
    retryResolve = resolve
    retryTimer = setTimeout(resolve, ms)
    retryTimer.unref?.()
  })
  const stream = async () => {
    let failures = 0
    while (!signal.aborted) {
      try {
        for await (const event of ctx.event.subscribe({ types: eventTypes, signal })) {
          if (signal.aborted) break
          failures = 0
          // V2.1.1 Promise adapter ignores subscribe.types; filter again locally.
          if (!eventTypes.includes(event.type)) continue
          if (event.location?.directory && event.location.directory !== ctx.location.directory &&
              !(event.type === "session.moved" &&
                state.sessions.get(event.data?.sessionID)?.directory === ctx.location.directory)) continue
          // Never retain prompt, answer, tool output, or error body in the queue.
          const data = event.data ?? {}
          queue.push({ id: event.id, type: event.type, created: event.created,
            data: { sessionID: data.sessionID, id: data.id, requestID: data.requestID,
              ...(data.form ? { form: { id: data.form.id, sessionID: data.form.sessionID } } : {}) } })
          if (queue.length > 512) queue.shift()
          void drain()
        }
      } catch { /* Source failure: reconnect with capped backoff, no replay. */ }
      if (signal.aborted) return
      await wait(Math.min(30_000, 1000 * 2 ** Math.min(failures++, 5)))
      if (!signal.aborted) void refresh()
    }
  }
  const heartbeatTimer = setInterval(publish, heartbeat)
  const resyncTimer = setInterval(() => void refresh(), resync)
  heartbeatTimer.unref?.()
  resyncTimer.unref?.()
  publish()
  void stream().catch(() => {})
  void refresh()
  return () => {
    controller.abort()
    clearInterval(heartbeatTimer)
    clearInterval(resyncTimer)
    clearTimeout(debounce)
    clearTimeout(retryTimer)
    retryResolve?.()
    queue.length = 0
    writer.close()
  }
}
