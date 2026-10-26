"use strict";
const toggle = document.getElementById("enabled");
const retry = document.getElementById("retry");
function render(status) {
  toggle.checked = status.enabled;
  document.getElementById("state").textContent = !status.enabled ? "Off" : status.connected && status.networkAvailable ? "Ready" : "Needs attention";
  document.getElementById("detail").textContent = !status.enabled
    ? "YouTube follows your normal network route."
    : status.error || (!status.connected ? "The helper is unavailable. Run the helper installer, then reconnect."
      : !status.networkAvailable ? "Waiting for a physical Wi-Fi or Ethernet connection."
        : `Using ${status.interface}. ${status.requestsRouted} requests routed this session.`);
  document.getElementById("domains").replaceChildren(...status.domains.map(domain => {
    const item = document.createElement("li"); item.textContent = domain; return item;
  }));
  retry.hidden = !status.enabled;
}
async function send(message) {
  toggle.disabled = true; retry.disabled = true;
  try { render(await browser.runtime.sendMessage(message)); }
  catch { document.getElementById("detail").textContent = "Cannot reach the extension. Reload it and try again."; }
  finally { toggle.disabled = false; retry.disabled = false; }
}
toggle.addEventListener("change", () => send({ type: "toggle", enabled: toggle.checked }));
retry.addEventListener("click", () => send({ type: "retry" }));
browser.runtime.onMessage.addListener(message => {
  if (message.type === "statusChanged") render(message.status);
});
send({ type: "status" });
