const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const vm = require("node:vm");
const path = require("node:path");
const policy = require("../extension/policy.js");
const NativeClient = require("../extension/native-client.js");
const root = path.resolve(__dirname, "..");

function event() {
  const listeners = [];
  return { addListener: listener => listeners.push(listener), emit: value => listeners.map(listener => listener(value)), listeners };
}
function fakePort() {
  const port = { onMessage: event(), onDisconnect: event(), postMessage() {}, disconnect() { port.onDisconnect.emit(); } };
  return port;
}
function ready(port = 40321) {
  return { type: "ready", protocolVersion: 1, version: "0.1.0", interface: "en0", networkAvailable: true,
    proxy: { host: "127.0.0.1", port, username: "daybreak", password: "ephemeral-secret" } };
}
const tick = () => new Promise(resolve => setImmediate(resolve));

test("domain policy, permissions and helper allowlist stay aligned", () => {
  for (const url of ["https://youtube.com/watch?v=1", "https://WWW.YOUTUBE.COM./", "https://r1.googlevideo.com/videoplayback"]) {
    assert.equal(policy.isYouTubeURL(url), true, url);
  }
  for (const url of ["https://youtube.com.attacker.test/", "https://notyoutube.com/", "https://google.com/", "file:///youtube.com", "garbage"]) {
    assert.equal(policy.isYouTubeURL(url), false, url);
  }
  const manifest = JSON.parse(fs.readFileSync(path.join(root, "extension/manifest.json")));
  assert.deepEqual(manifest.permissions.filter(p => p.includes("://")), policy.filter.urls);
  const swift = fs.readFileSync(path.join(root, "Sources/DaybreakCore/DomainPolicy.swift"), "utf8");
  const swiftDomains = [...swift.match(/youtubeDomains = \[([\s\S]*?)\]/)[1].matchAll(/"([^"]+)"/g)].map(match => match[1]);
  assert.deepEqual(swiftDomains, policy.domains);
});

test("proxy selection uses remote DNS and terminates browser proxy fallback", () => {
  const route = policy.proxyFor(ready().proxy);
  assert.equal(route[0].type, "socks");
  assert.equal(route[0].proxyDNS, true);
  assert.equal(route[0].password, "ephemeral-secret");
  assert.equal(route.at(-1), null);
  assert.equal(policy.unavailableProxy()[0].host, "127.0.0.1");
  assert.equal(policy.unavailableProxy().at(-1), null);
});

test("native client shares startup, handles helper loss, then reconnects with fresh credentials", async () => {
  const ports = [];
  const client = new NativeClient(() => { const port = fakePort(); ports.push(port); return port; });
  const first = client.connect();
  assert.equal(client.connect(), first);
  assert.equal(ports.length, 1);
  ports[0].onMessage.emit(ready());
  assert.equal((await first).port, 40321);
  ports[0].onDisconnect.emit();
  assert.equal(client.endpoint, null);
  const second = client.connect();
  ports[1].onMessage.emit(ready(40322));
  assert.equal((await second).port, 40322);
  client.disconnect();
});

test("native client rejects incompatible and non-loopback endpoints", async () => {
  for (const mutate of [message => { message.protocolVersion = 2; }, message => { message.proxy.host = "0.0.0.0"; }]) {
    const port = fakePort();
    const client = new NativeClient(() => port);
    const pending = client.connect();
    const message = ready(); mutate(message); port.onMessage.emit(message);
    await assert.rejects(pending, /incompatible/);
    assert.equal(client.endpoint, null);
  }
});

test("native startup failure and cancellation are bounded", async () => {
  const port = fakePort();
  const client = new NativeClient(() => port, () => {}, 10);
  await assert.rejects(client.connect(), /did not respond/);
  assert.equal(client.port, null);
  const cancelled = new NativeClient(() => fakePort());
  const pending = cancelled.connect(); cancelled.disconnect();
  await assert.rejects(pending, /cancelled/);
});

function background() {
  const ports = [];
  const saved = [];
  const browser = {
    browserAction: { setBadgeText: async () => {}, setBadgeBackgroundColor: async () => {} },
    storage: { local: { get: async () => ({ enabled: true }), set: async value => saved.push(value) } },
    runtime: { connectNative: () => { const port = fakePort(); ports.push(port); return port; },
      onMessage: event(), sendMessage: async () => {} },
    proxy: { onRequest: event(), onError: event() }
  };
  const context = vm.createContext({ browser, URL, setTimeout, clearTimeout, console, Date });
  for (const name of ["policy.js", "native-client.js", "background.js"]) {
    vm.runInContext(fs.readFileSync(path.join(root, "extension", name), "utf8"), context, { filename: name });
  }
  return { browser, ports, saved, route: browser.proxy.onRequest.listeners[0], message: browser.runtime.onMessage.listeners[0] };
}

test("background waits for helper startup and doesn't expose credentials in UI/storage", async () => {
  const app = background();
  const pending = app.route({ url: "https://youtube.com/" });
  let resolved = false; pending.then(() => { resolved = true; });
  await tick(); assert.equal(resolved, false);
  app.ports[0].onMessage.emit(ready());
  assert.equal((await pending)[0].port, 40321);
  const status = await app.message({ type: "status" });
  assert.equal(status.connected, true);
  assert.equal(JSON.stringify(status).includes("ephemeral-secret"), false);
  assert.equal(JSON.stringify(app.saved).includes("ephemeral-secret"), false);
  await app.message({ type: "toggle", enabled: false });
  assert.equal((await app.route({ url: "https://youtube.com/" })).type, "direct");
});

test("helper startup failure blocks selected traffic instead of returning direct", async () => {
  const app = background();
  const pending = app.route({ url: "https://r1.googlevideo.com/videoplayback" });
  await tick(); app.ports[0].error = { message: "No such native application" }; app.ports[0].onDisconnect.emit();
  const route = await pending;
  assert.equal(route[0].host, "127.0.0.1");
  assert.equal(route[0].port, 9);
  assert.equal(route.at(-1), null);
});
