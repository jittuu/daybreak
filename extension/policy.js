(function (root) {
  "use strict";
  const domains = Object.freeze([
    "youtube.com", "youtu.be", "googlevideo.com", "ytimg.com",
    "youtube-nocookie.com", "youtubei.googleapis.com"
  ]);
  function isYouTubeURL(value) {
    try {
      const url = new URL(value);
      if (url.protocol !== "http:" && url.protocol !== "https:") return false;
      const host = url.hostname.toLowerCase().replace(/\.$/, "");
      return domains.some(domain => host === domain || host.endsWith("." + domain));
    } catch { return false; }
  }
  function proxyFor(endpoint) {
    // A terminal null suppresses Firefox's fallback to a browser-defined proxy.
    return [{
      type: "socks", host: endpoint.host, port: endpoint.port,
      username: endpoint.username, password: endpoint.password,
      proxyDNS: true, failoverTimeout: 15,
      connectionIsolationKey: "daybreak-v1"
    }, null];
  }
  const unavailableProxy = () => proxyFor({ host: "127.0.0.1", port: 9, username: "unavailable", password: "unavailable" });
  const policy = Object.freeze({ domains, isYouTubeURL, proxyFor, unavailableProxy,
    filter: { urls: domains.map(domain => `*://*.${domain}/*`) } });
  root.DaybreakPolicy = policy;
  if (typeof module !== "undefined") module.exports = policy;
})(globalThis);
