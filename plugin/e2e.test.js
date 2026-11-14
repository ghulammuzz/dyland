import assert from "node:assert/strict"
import { spawn } from "node:child_process"
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"
import { setTimeout as sleep } from "node:timers/promises"
import { bridgePath } from "./bridge.js"

// Explicit opt-in: starts isolated OpenCode server; no model calls or global config edits.
const root = dirname(fileURLToPath(import.meta.url))
const directory = mkdtempSync(join(root, ".e2e-"))
writeFileSync(join(directory, "opencode.json"), JSON.stringify({ plugins: [root] }))
const child = spawn("opencode", ["serve", "--hostname", "127.0.0.1", "--port", "0"], { cwd: directory })
let output = ""
child.stdout.on("data", (chunk) => { output += chunk })
child.stderr.on("data", (chunk) => { output += chunk })
let sessionID
let api
const until = async (check) => {
  for (let i = 0; i < 300; i++) {
    const result = await check()
    if (result) return result
    if (child.exitCode !== null) throw new Error(`OpenCode exited: ${child.exitCode}`)
    await sleep(100)
  }
  throw new Error("E2E condition timed out")
}
try {
  await until(() => /server password \S+/.test(output))
  const url = output.match(/server listening on (\S+)/)[1]
  const password = output.match(/server password (\S+)/)[1]
  api = async (path, method = "GET", body) => {
    const response = await fetch(new URL(path, url), { method,
      headers: { authorization: `Basic ${Buffer.from(`opencode:${password}`).toString("base64")}`,
        "content-type": "application/json" },
      ...(body ? { body: JSON.stringify(body) } : {}), signal: AbortSignal.timeout(5000) })
    assert.ok(response.ok, `${method} ${path}: ${response.status}`)
    return response.status === 204 ? undefined : response.json()
  }
  const plugins = `/api/plugin?location%5Bdirectory%5D=${encodeURIComponent(directory)}`
  await until(async () => (await api(plugins)).data.find((plugin) =>
    plugin.id === "dyland.bridge" && plugin.state.status === "active"))
  sessionID = (await api("/api/session", "POST", { title: "Dyland E2E", location: { directory } })).data.id
  const read = () => { try { return JSON.parse(readFileSync(bridgePath(directory))) } catch { return undefined } }
  await until(() => read()?.sessions.some((session) => session.id === sessionID))
  assert.equal(read().notices.length, 0)
  const form = (await api(`/api/session/${sessionID}/form`, "POST", {
    title: "Private form body", fields: [{ type: "boolean", key: "confirm", required: true }],
  })).data
  await until(() => read()?.pending.some((pending) => pending.requestID === form.id))
  const notice = read().notices.find((notice) => notice.requestID === form.id)
  assert.equal(notice.kind, "question")
  assert.match(notice.id, /^evt_/)
  assert.ok(!JSON.stringify(read()).includes("Private form body"))
  await api(`/api/session/${sessionID}/form/${form.id}/reply`, "POST", { answer: { confirm: true } })
  await until(() => read()?.pending.length === 0 && read()?.notices.some((notice) => notice.kind === "resolved"))
  const childSessionID = (await api("/api/session", "POST", {
    title: "Dyland deletion child E2E", parentID: sessionID, location: { directory },
  })).data.id
  const children = await api(`/api/session?parentID=${sessionID}&limit=200`)
  assert.ok(children.data.some((session) => session.id === childSessionID))
  const active = await api("/api/session/active")
  assert.ok(!active.data[sessionID] && !active.data[childSessionID])
  const deletedID = sessionID
  await api(`/api/session/${sessionID}`, "DELETE")
  sessionID = undefined
  await until(() => {
    const snapshot = read()
    return snapshot && !snapshot.sessions.some((session) => session.id === deletedID) &&
      !snapshot.pending.some((pending) => pending.sessionID === deletedID)
  })
  const remaining = await api("/api/session?limit=200")
  assert.ok(!remaining.data.some((session) => [deletedID, childSessionID].includes(session.id)))
  if (process.env.DYLAND_DELETE_CHECK) {
    const check = spawn(process.env.DYLAND_DELETE_CHECK, [], { stdio: "inherit", env: {
      ...process.env, DYLAND_E2E_SERVER: url, OPENCODE_PASSWORD: password, DYLAND_E2E_DIRECTORY: directory,
    } })
    const code = await new Promise((resolve, reject) => {
      check.once("error", reject)
      check.once("exit", resolve)
    })
    assert.equal(code, 0, "Swift session deletion E2E must pass")
  }
  console.log("OpenCode 2.1.1 E2E passed: active plugin, global session list, native forms, private JSON, cascading deletion and bridge cleanup")
} finally {
  if (sessionID) await api(`/api/session/${sessionID}`, "DELETE").catch(() => {})
  child.kill("SIGTERM")
  await new Promise((resolve) => { if (child.exitCode !== null) resolve(); else child.once("exit", resolve) })
  rmSync(directory, { recursive: true, force: true })
  rmSync(bridgePath(directory), { force: true })
}
