# Prototype validation — 2026-10-26

Environment: Apple Silicon, macOS 27.0.1, Swift 6.4, Zen 1.23.4b.

## Passed

- Six Swift tests covering production hostname policy, native framing, bounded
  HTTP content-length/chunk decoding, and DNS response/address/TTL parsing.
- Seven JavaScript tests covering domain/permission alignment, native startup and
  reconnect behavior, bounded startup failures, proxy fallback suppression, and
  keeping credentials out of popup state and extension storage.
- Five integration tests against the real helper: fragmented SOCKS authentication,
  incorrect credentials, disallowed destinations/ports/IP literals/UDP, invalid
  native frames, native status, and shutdown on stdin EOF.
- Real HTTPS forwarding through `en0`: YouTube robots file returned HTTP 200;
  full YouTube homepage returned HTTP 200 with 865,048 received bytes. Upstream
  TLS certificates were verified by the client. The larger response exercises
  forwarding across multiple bounded read/write operations.
- Real Zen test in a disposable headless profile: add-on loaded, native helper
  launched, YouTube request returned HTTP 200, one selected request was routed,
  unrelated navigation to example.com did not enter the proxy, disabling the
  add-on disconnected the native port, and its one helper process exited.

## Exit-node-enabled playback verification — passed

A later live run enabled the already-configured exit node (ID 27), with the user's
explicit authorization. Tailscale was running and the exit node was online. The
saved DNS, route-acceptance, and LAN-access options were preserved.

- Ordinary Zen browsing showed the exit node's public IPv4 address both before
  playback and in another tab during playback. It differed from the Wi-Fi-bound
  public IPv4 address.
- The official Big Buck Bunny YouTube video played at 854 × 480 in a disposable,
  muted, headless Zen profile. Media time advanced from 0.867 to 31.247 seconds;
  reported frames increased from 27 to 937, with zero dropped frames and no player
  error. Playback continued while checking ordinary browsing (33.419 seconds,
  1,002 reported frames afterward).
- Resource timing identified the actual `googlevideo.com` streaming hostname.
  Direct DNS results matched a helper TLS socket observed by macOS `nettop` on
  `en0`, receiving 4,842,698 bytes. All observed external helper HTTPS sockets
  used `en0`; browser-to-helper sockets used loopback.
- The extension reported no helper/proxy error. No production code change was
  needed. A repeatable opt-in test was added as `Tests/exit_node_playback.py`.

This establishes playback and bypass for the tested TCP/IPv4 path and current
Tailscale/macOS/Zen versions; it does not establish all browser transports or
network-change cases. Full local diagnostics are in `.build/playback/` (gitignored).
The configured exit node was left enabled as requested. The existing Zen profile
was not modified; test browser/helper processes were stopped after the run.

## Observed footprint

| Item | Measurement |
| --- | --- |
| Release helper binary | 317,616 bytes (about 310 KiB) |
| Unsigned extension XPI | 5,791 bytes (about 5.7 KiB) |
| Helper RSS after one browser request | 13,216 KiB (about 12.9 MiB) |
| Third-party runtime packages | None |

These are observations from this machine and build, not steady-state guarantees
or a complete performance profile. RSS includes shared framework pages. Swift
and Apple networking frameworks are supplied by macOS rather than bundled.

## Not yet established

- Seek, long-running streams, and HTTP/3/QUIC behavior beyond the tested TCP path.
- IPv6 egress, Wi-Fi/Ethernet transitions, sleep/wake, captive portals, and VPN
  variants that enforce physical-egress restrictions.
- Persistent signed add-on installation and Intel builds.

The helper is installed under `~/Library/Application Support/Daybreak/` with its
user-level Mozilla native-host manifest. The add-on was tested only in a disposable
profile; the existing Zen profile has not been changed. No helper remains running
after those tests. Source and unsigned development XPI are ready for the next run.

## Daybreak naming and distribution check — passed

All package/target names, executable and application paths, extension globals,
add-on/native-host IDs, UI labels, documentation, and installer scripts now use
Daybreak. The previous helper installation was migrated to the new native identity.

- All 18 automated tests passed after the rename.
- The packaged add-on matched every source file. The actual release installer
  succeeded in a disposable prefix; its manifest identity, executable version,
  native startup, and EOF shutdown matched the add-on.
- The renamed add-on/native host passed the real Zen browser test.
- A fresh exit-node-enabled run advanced the YouTube video from 1.005 to 31.176
  seconds, with reported frames increasing from 30 to 936 and zero drops. A matching
  video CDN socket received 2,438,291 bytes over `en0`. Ordinary browsing retained
  the exit node's public IP during playback.

GitHub Actions is configured to run portable extension behavior and package checks
on standard Ubuntu runners. macOS tests remain local, per the repository owner's
request. The repository's initial MIT license and author attribution are preserved.
