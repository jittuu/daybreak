"use strict";

const policy = globalThis.DaybreakPolicy;
let enabled = true;
let requestsRouted = 0;
let lastConnectionError = null;
let retryAfter = 0;

function updateBadge() {
  const text = !enabled ? "OFF" : native.endpoint && native.networkAvailable ? "ON" : "!";
  browser.browserAction.setBadgeText({ text }).catch(() => {});
  browser.browserAction.setBadgeBackgroundColor({ color: text === "ON" ? "#26775f" : "#735739" }).catch(() => {});
  browser.runtime.sendMessage({ type: "statusChanged", status: snapshot() }).catch(() => {});
}
const native = new globalThis.DaybreakNativeClient(
  name => browser.runtime.connectNative(name), updateBadge
);
const settingsReady = browser.storage.local.get({ enabled: true }).then(settings => {
  enabled = settings.enabled !== false;
  updateBadge();
}).catch(() => updateBadge());

function snapshot() {
  return {
    enabled, connected: native.endpoint !== null, networkAvailable: native.networkAvailable,
    interface: native.networkInterface, helperVersion: native.version,
    error: native.error, lastConnectionError, requestsRouted, domains: policy.domains
  };
}

async function endpoint() {
  if (!native.endpoint && Date.now() < retryAfter) throw new Error("Waiting before retry");
  try { return await native.connect(); }
  catch (error) { retryAfter = Date.now() + 5000; throw error; }
}

// Registered synchronously so requests cannot slip through while storage/native startup is pending.
browser.proxy.onRequest.addListener(async request => {
  await settingsReady;
  if (!enabled || !policy.isYouTubeURL(request.url)) return { type: "direct" };
  try {
    const proxy = await endpoint();
    // Toggling off while the helper starts should apply to this request too.
    if (!enabled) return { type: "direct" };
    requestsRouted += 1;
    return policy.proxyFor(proxy);
  } catch {
    return enabled ? policy.unavailableProxy() : { type: "direct" };
  }
}, policy.filter);

browser.proxy.onError.addListener(error => {
  lastConnectionError = error.message || "A proxy request failed";
});

browser.runtime.onMessage.addListener(async message => {
  await settingsReady;
  if (message.type === "toggle") {
    enabled = message.enabled === true;
    await browser.storage.local.set({ enabled });
    retryAfter = 0;
    lastConnectionError = null;
    if (enabled) await endpoint().catch(() => {});
    else native.disconnect();
    updateBadge();
  } else if (message.type === "retry") {
    native.disconnect();
    retryAfter = 0;
    lastConnectionError = null;
    if (enabled) await endpoint().catch(() => {});
    updateBadge();
  } else if (message.type === "status") { native.refresh(); }
  // Never send ephemeral proxy credentials to the popup or persist them.
  return snapshot();
});

settingsReady.then(() => { if (enabled) endpoint().catch(() => updateBadge()); });
