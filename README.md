# Daybreak

[![CI](https://github.com/jittuu/daybreak/actions/workflows/ci.yml/badge.svg)](https://github.com/jittuu/daybreak/actions/workflows/ci.yml)

A small macOS helper and Zen/Firefox add-on that sends YouTube over your physical
Wi-Fi or Ethernet connection while other traffic follows the existing system route.
Keep the official Tailscale client and your exit node enabled.

**Status:** early development prototype. macOS 13+, initially developed on Apple
Silicon. The helper needs a working direct connection to YouTube; it cannot make
a locally blocked service reachable. This does not enforce an always-on VPN for
other traffic: that remains the responsibility of your existing VPN client.

## Architecture

```text
Zen ── YouTube hostnames ── localhost SOCKS5 ── physical interface ── YouTube
    └─ everything else ── existing system networking ── Tailscale exit node
```

- The add-on chooses routes from the actual request hostname using Firefox's
  `proxy.onRequest` API. Only the listed service domains are intercepted.
- One Swift executable provides an authenticated, loopback-only SOCKS5 listener.
  It constrains DNS and content connections with `NWParameters.requiredInterface`.
- DNS uses Cloudflare's DoH JSON endpoint, reached by a bootstrap IP over the
  same physical interface. A/AAAA results are coalesced and cached up to their TTL
  (capped at five minutes), with at most 128 cached entries.
- The browser launches the helper with native messaging. This channel carries
  startup credentials and status, never video bytes. The helper exits on stdin
  EOF when the browser disconnects.
- Network path monitors respond to physical-network changes. There is no periodic
  polling, Tailscale library, packet tunnel, root service, or system-wide proxy change.
- Relays use backpressure and 32 KiB chunks per direction. The helper caps active
  connections at 128 and concurrent distinct DNS lookups at 32.

## Build and test

Requires macOS, Swift 5.9+ / Xcode Command Line Tools, and Python 3. Node.js 18+
is used only for development tests. There are no third-party package dependencies.

```sh
make build
make test
make check-distribution
```

`make test` runs Swift parser/policy tests, add-on behavior tests, and real helper
integration tests over native stdio and localhost. It does not contact the internet.

`make check-distribution` builds the release helper, installs it into a disposable
directory, checks its real native startup/shutdown and add-on identity, and validates
the unsigned XPI against the current extension source. It leaves the user's native
host registration alone.

GitHub Actions runs the extension behavior tests and `make check-package` on a
standard Ubuntu runner for pushes, pull requests, and manual dispatch. macOS tests
are run locally: `make test` and `make check-distribution` cover the Swift helper,
real native protocol, and installer. Live Zen/YouTube/Tailscale tests remain opt-in
on a configured Mac.

An opt-in live test verifies real remote DNS, SOCKS authentication, streaming, and
upstream TLS without installing anything or changing your browser:

```sh
python3 scripts/smoke-test.py
python3 scripts/smoke-test.py --path /
```

This test alone does **not** prove VPN bypass. Run with an exit node active and
verify the egress interface/public IP independently before relying on that claim.

After installing the helper and packaging the add-on, run the actual browser test:

```sh
python3 Tests/browser_smoke.py
```

It launches a disposable headless Zen profile, loads the temporary add-on, checks
native startup and a real YouTube request, verifies unrelated browsing stays out
of the proxy, and confirms the helper exits after disabling. It does not touch
your existing Zen profile. The native helper registration must already be installed.

For a live playback/egress comparison, first enable your intended Tailscale exit
node, then run:

```sh
python3 Tests/exit_node_playback.py --seconds 30
```

This test asserts different system and physical public IPv4 addresses, confirms
ordinary Zen browsing uses the exit-node address before and during playback,
requires video time/frame progression, and correlates the video CDN with real
helper socket traffic on the physical interface. It leaves Tailscale enabled.
Use `--physical-interface=en4` if the helper selects Ethernet instead of `en0`.
Evidence is saved under `.build/playback/`. See VALIDATION.md for the completed run.

## Try in Zen

1. Install the native helper and its user-level browser registration:

   ```sh
   bash scripts/install-helper.sh
   ```

   This builds a release binary and installs it under
   `~/Library/Application Support/Daybreak/`. The native manifest is installed
   in `~/Library/Application Support/Mozilla/NativeMessagingHosts/`, which Zen
   currently uses. No administrator rights or browser preference edits are needed.

2. In Zen open `about:debugging#/runtime/this-firefox`, choose **Load Temporary
   Add-on**, and select this project's `extension/manifest.json`.
3. Open the **Daybreak** toolbar popup. It should report **Ready** and a physical
   interface such as `en0`.
4. Keep your Tailscale exit node enabled, then open a fresh YouTube tab. An ordinary
   public-IP checker should still show the exit node's IP. Confirm the YouTube
   connections use your physical connection before considering bypass verified.

The temporary add-on is removed when Zen restarts. `make package` produces an
unsigned development XPI under `dist/`; normal persistent installation requires
Mozilla add-on signing. This repository does not disable signature enforcement.

To remove the helper:

```sh
bash scripts/uninstall-helper.sh
```

Then remove the add-on in Zen. Existing YouTube connections may keep their original
route after a toggle; reload the page or restart the browser when testing changes.

## Included domains

The service list includes each domain and its subdomains:

```text
youtube.com
youtu.be
googlevideo.com
ytimg.com
youtube-nocookie.com
youtubei.googleapis.com
```

The extension and helper both enforce this list. A test catches differences between
the two. Avoid broad exemptions such as `google.com` or `googleapis.com`. Rules are
by destination, not by tab: an embedded YouTube player on another site uses the same
domain routes. This list is a starting service definition; additional endpoints
may need explicit additions as YouTube changes.

## Failure behavior and scope

- While enabled, helper failure makes selected requests fail rather than silently
  fall back to a browser-defined proxy/system route. While disabled, YouTube follows
  your usual network settings. Removing/disabling the add-on also restores normal
  browser routing.
- The helper requires ephemeral SOCKS credentials and accepts only allowed domain
  names on TCP ports 80 and 443. Literal IPs, arbitrary hosts, BIND and UDP ASSOCIATE
  are rejected. Credentials stay in memory and are not written to extension storage.
- V1 implements TCP SOCKS forwarding. QUIC/HTTP3, connection reuse/coalescing and
  browser DNS speculation need browser-level verification. The add-on is not a
  guarantee that every YouTube-related DNS query or every browser transport bypasses
  the VPN. It never decrypts browser HTTPS or installs a root certificate.
- The initial resolver uses the IPv4 bootstrap address `1.1.1.1`; IPv6-only networks
  and networks that block that resolver need additional resolver support.
- The physical-interface constraint must be validated against the installed
  Tailscale variant, OS, IPv4/IPv6, and network changes. If a VPN/network policy blocks
  physical egress, the helper reports connection failure rather than overriding it.
- Zen has had native-messaging regressions; use a current release if the helper
  starts in CLI tests but not from the browser.

## Standalone diagnostics

```sh
.build/release/daybreak-helper --serve --interface=en0
```

The first line is JSON containing the random local port and ephemeral credentials.
Treat that line as a local secret. Press Ctrl-C to stop. `--interface` is optional;
automatic selection prefers connected Ethernet, then Wi-Fi. Standalone-only
`--allow-domain=example.com` adds a temporary diagnostic destination; native mode
does not accept this override. The executable never enables/disables Tailscale.

## Next milestones

1. Extend the verified TCP/IPv4 playback path to IPv6 and network-change cases.
2. Test seeking, long playback, helper loss, and Wi-Fi changes in Zen. Add
   transport-specific handling only where evidence requires it.
3. Sign the add-on and package a small installer for persistent everyday use.

References: [Firefox proxy API](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/API/proxy/onRequest),
[native messaging](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/Native_messaging),
[Apple interface selection](https://developer.apple.com/documentation/network/nwparameters/requiredinterface),
[Cloudflare DoH](https://developers.cloudflare.com/1.1.1.1/encryption/dns-over-https/make-api-requests/).

MIT licensed. See [LICENSE](LICENSE).
