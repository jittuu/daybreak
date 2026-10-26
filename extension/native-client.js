(function (root) {
  "use strict";
  class NativeClient {
    constructor(connectNative, onChange = () => {}, timeout = 8000) {
      this.connectNative = connectNative;
      this.onChange = onChange;
      this.timeout = timeout;
      this.port = null;
      this.endpoint = null;
      this.connecting = null;
      this.error = null;
      this.networkInterface = null;
      this.networkAvailable = false;
      this.version = null;
      this.rejectPending = null;
    }
    connect() {
      if (this.endpoint && this.port) return Promise.resolve(this.endpoint);
      if (this.connecting) return this.connecting;
      this.connecting = new Promise((resolve, reject) => {
        let port;
        let settled = false;
        const fail = message => {
          if (settled) return;
          settled = true;
          clearTimeout(timer);
          this.rejectPending = null;
          this.error = message;
          this.onChange();
          reject(new Error(message));
        };
        const timer = setTimeout(() => {
          fail("The helper did not respond. Install it or update Zen, then retry.");
          if (this.port === port) this.disconnect();
        }, this.timeout);
        this.rejectPending = fail;
        try {
          port = this.connectNative("app.daybreak.helper");
          this.port = port;
          port.onMessage.addListener(message => {
            if (this.port !== port) return;
            if (message.type === "error") { fail(message.message || "Helper error"); this.disconnect(); return; }
            if (!["ready", "status"].includes(message.type)) return;
            const proxy = message.proxy;
            if (message.protocolVersion !== 1 || !proxy || proxy.host !== "127.0.0.1" ||
                !Number.isInteger(proxy.port) || proxy.port < 1 || proxy.port > 65535 ||
                typeof proxy.username !== "string" || typeof proxy.password !== "string" || !proxy.password) {
              fail("The helper and extension are incompatible. Reinstall the helper.");
              this.disconnect();
              return;
            }
            this.endpoint = { ...proxy };
            this.networkInterface = message.interface || null;
            this.networkAvailable = message.networkAvailable === true;
            this.version = message.version;
            this.error = null;
            if (!settled) {
              settled = true;
              clearTimeout(timer);
              this.rejectPending = null;
              resolve(this.endpoint);
            }
            this.onChange();
          });
          port.onDisconnect.addListener(() => {
            if (this.port !== port) return;
            const reason = port.error?.message || "The helper stopped. Retry to reconnect.";
            this.port = null;
            this.endpoint = null;
            this.networkAvailable = false;
            this.error = reason;
            fail(reason);
            this.onChange();
          });
        } catch (error) { fail(error.message || "Cannot start the helper"); }
      });
      const pending = this.connecting;
      // Clear on either outcome without creating an unhandled rejected promise.
      pending.then(() => { if (this.connecting === pending) this.connecting = null; },
        () => { if (this.connecting === pending) this.connecting = null; });
      return pending;
    }
    refresh() { if (this.port && this.endpoint) this.port.postMessage({ type: "status" }); }
    disconnect() {
      const port = this.port;
      this.port = null;
      this.endpoint = null;
      this.networkAvailable = false;
      this.rejectPending?.("Connection cancelled");
      this.rejectPending = null;
      if (port) port.disconnect();
      this.onChange();
    }
  }
  root.DaybreakNativeClient = NativeClient;
  if (typeof module !== "undefined") module.exports = NativeClient;
})(globalThis);
