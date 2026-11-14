import test from "node:test"
import assert from "node:assert/strict"
import { existsSync, mkdtempSync, readFileSync, readdirSync, rmSync, utimesSync, writeFileSync } from "node:fs"
import { stripTypeScriptTypes } from "node:module"
import { tmpdir } from "node:os"
import { join } from "node:path"

const nonce = "12345678-1234-1234-1234-123456789abc"
const nextNonce = "12345678-1234-1234-1234-123456789abd"

async function runtime(t) {
  const home = mkdtempSync(join(tmpdir(), "dyland-tui-"))
  let cleanup
  t.after(() => {
    cleanup?.()
    rmSync(home, { recursive: true, force: true })
  })
  // OpenCode supplies Solid/TUI host. Keep real setup and filesystem, replace only host/runtime boundaries.
  const source = readFileSync(new URL("./tui.ts", import.meta.url), "utf8")
    .replace('import { Plugin } from "@opencode/plugin/tui"', "const Plugin = { define: value => value }")
    .replace('import { homedir } from "node:os"', `const homedir = () => ${JSON.stringify(home)}`)
  const module = await import("data:text/javascript;base64," + Buffer.from(stripTypeScriptTypes(source)).toString("base64"))
  let now = Date.now()
  let tick
  const timer = Symbol("timer")
  t.mock.method(Date, "now", () => now)
  t.mock.method(globalThis, "setInterval", (callback, delay) => {
    assert.equal(delay, 250)
    tick = callback
    return timer
  })
  const clear = t.mock.method(globalThis, "clearInterval", (value) => assert.equal(value, timer))
  const navigations = []
  const toasts = []
  const context = {
    location: { directory: "/project" },
    ui: {
      router: {
        current: () => current,
        navigate: (route) => navigations.push(route),
      },
      tabs: {
        enabled: () => true,
        list: () => ["ses_root", "ses_child", "ses_child", "invalid"].map((sessionID) => ({ sessionID })),
      },
      toast: { show: (toast) => toasts.push(toast) },
    },
  }
  let current = { type: "session", sessionID: "ses_root" }
  cleanup = module.default.setup(context)
  assert.equal(typeof cleanup, "function")
  const directory = join(home, "Library", "Application Support", "Dyland", "routes")
  const [filename] = readdirSync(directory)
  const path = join(directory, filename)
  const stem = path.slice(0, -5)
  return {
    module, directory, path, navigations, toasts, clear,
    requestPath: `${stem}.request.json`,
    ackPath: `${stem}.ack.json`,
    terminalPath: `${stem}.terminal.json`,
    read: (path) => JSON.parse(readFileSync(path, "utf8")),
    request(value, age = 0) {
      writeFileSync(this.requestPath, JSON.stringify(value))
      utimesSync(this.requestPath, (now - age) / 1_000, (now - age) / 1_000)
    },
    tick(elapsed = 250) { now += elapsed; tick() },
    current(sessionID) { current = { type: "session", sessionID } },
    cleanup() { cleanup(); cleanup = undefined },
  }
}

test("TUI routing validates request IDs without loading host UI", async (t) => {
  const { module } = await runtime(t)
  module.selfCheck()
  for (const request of [
    { sessionID: "ses_valid", nonce: "../escape" },
    { sessionID: "ses_valid\n", nonce },
    { sessionID: "../escape", nonce },
    { sessionID: "ses_valid", nonce: `${nonce}\n` },
  ]) assert.equal(module.validRequest(request), false)
})

test("setup publishes sessions; navigation ACK waits for router confirmation; cleanup removes route files", async (t) => {
  const app = await runtime(t)
  const route = app.read(app.path)
  assert.deepEqual(route.sessionIDs, ["ses_root", "ses_child"])
  assert.equal(route.currentSessionID, "ses_root")
  assert.equal(route.directory, "/project")
  assert.equal(typeof route.updatedAt, "number")

  const request = { sessionID: "ses_child", nonce }
  app.request(request)
  app.tick()
  assert.deepEqual(app.navigations, [{ type: "session", sessionID: "ses_child" }])
  assert.equal(existsSync(app.ackPath), false)
  app.tick()
  assert.equal(existsSync(app.ackPath), false)
  app.current("ses_child")
  app.tick()
  assert.deepEqual(app.read(app.ackPath), request)
  assert.equal(app.read(app.path).currentSessionID, "ses_child")
  app.tick()
  assert.equal(app.navigations.length, 1, "same nonce must not navigate again")

  writeFileSync(app.terminalPath, "{}")
  assert.equal(readdirSync(app.directory).length, 4)
  app.cleanup()
  assert.deepEqual(readdirSync(app.directory), [])
  assert.equal(app.clear.mock.callCount(), 1)
  assert.deepEqual(app.toasts, [])
})

test("unconfirmed navigation times out without ACK or replay, then accepts fresh request", async (t) => {
  const app = await runtime(t)
  app.request({ sessionID: "ses_child", nonce })
  app.tick()
  app.tick(2_501)
  assert.equal(existsSync(app.ackPath), false)
  app.current("ses_child")
  app.tick()
  assert.equal(existsSync(app.ackPath), false, "late router confirmation must not ACK expired request")
  assert.equal(app.navigations.length, 1)

  const request = { sessionID: "ses_root", nonce: nextNonce }
  app.request(request)
  app.tick()
  assert.equal(app.navigations.length, 2)
  assert.equal(existsSync(app.ackPath), false)
  app.current("ses_root")
  app.tick()
  assert.deepEqual(app.read(app.ackPath), request)
  assert.deepEqual(app.toasts, [])
})

test("tick rejects stale, future, malformed and unknown-session requests", async (t) => {
  const app = await runtime(t)
  const request = { sessionID: "ses_child", nonce }
  for (const age of [3_001, -2_000]) {
    app.request(request, age)
    app.tick(0)
  }
  app.request({ sessionID: "ses_missing", nonce })
  app.tick(0)
  app.request({ sessionID: "ses_child", nonce: "../escape" })
  app.tick(0)
  writeFileSync(app.requestPath, "not JSON")
  app.tick(0)
  assert.deepEqual(app.navigations, [])
  assert.equal(existsSync(app.ackPath), false)
  assert.deepEqual(app.toasts, [])

  // Rejected requests must not consume the nonce.
  app.request(request)
  app.tick(0)
  assert.deepEqual(app.navigations, [{ type: "session", sessionID: "ses_child" }])
})
