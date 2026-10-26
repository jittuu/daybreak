# Working on Daybreak

This is a macOS-only prototype: a Firefox-compatible Zen extension plus a small
Swift native-messaging host. Keep the official Tailscale client separate.

## Product invariants

- The existing Tailscale exit node stays in control of ordinary system traffic.
  Never silently enable/disable it, edit system routes, change Zen preferences,
  or install a system-wide proxy configuration.
- Selected YouTube requests use a localhost proxy whose DNS and content sockets
  are explicitly constrained to a physical Wi-Fi/Ethernet interface.
- Match by hostname boundaries, not substring or broad Google IP ranges. Keep
  extension permissions, extension policy, and helper allowlist aligned.
- Keep dependencies at zero, forward with bounded buffers, and use network events
  instead of periodic polling. Native messaging is for control, not video data.
- The native helper belongs to the browser connection and exits on stdin EOF.
- Keep ephemeral proxy credentials in memory only; never log them or send them
  to the popup. Enabled selected requests fail on helper failure; they must not
  silently fall back through another browser proxy.

## Verification

- `make check-package`: portable extension archive/source validation (also in CI).
- `make check-distribution`: release build and isolated native installer validation.
- `make test`: Swift production parser/policy tests, extension behavior tests,
  and real native-host/localhost integration tests. No internet required.
- `python3 scripts/smoke-test.py`: opt-in real YouTube HTTPS forwarding.
- `python3 Tests/browser_smoke.py`: opt-in real Zen test in a disposable profile;
  needs the installed helper and `make package` first.
- Changing helper code requires rebuilding/reinstalling the release helper before
  browser tests. Changing extension code requires `make package` before browser tests.
- A successful request while Tailscale is stopped is not proof of exit-node bypass.
  Do not claim playback, IPv6, failover, or VPN coexistence is verified without
  corresponding live evidence. Current results and open checks are in VALIDATION.md.

See README.md for architecture, limitations, installation, and removal.
