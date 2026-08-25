# Norn for macOS

Norn is a native control room for observing services, reviewing durable
operation receipts, and safely queuing platform or host maintenance. The app
uses Norn's versioned HTTPS and WebSocket control protocol; it does not connect
to the control-plane database or expose arbitrary shell execution.

## Current milestone

The first working milestone includes:

- A native `NavigationSplitView` shell with Overview, Apps, Operations,
  Releases, and Host surfaces.
- Multiple Norn server profiles with scoped tokens stored device-only in
  Keychain.
- HTTPS transport, authenticated WebSocket events, persisted replay cursors,
  exponential reconnect, and authoritative refresh after reconnect.
- Durable preflight, upgrade, rollback, smoke, and host-assurance actions with
  idempotency keys and visible receipts.
- Offline cached state, explicit request errors, fixture-backed Explore Mode,
  keyboard navigation, context menus, VoiceOver labels, semantic status, and
  Reduce Motion/Reduce Transparency support.

See [Docs/PROJECT_PLAN.md](Docs/PROJECT_PLAN.md) for the product principles,
architecture, and later protocol milestones.

## Run locally

1. Open `NornUI.xcodeproj` in Xcode.
2. Select the `NornUI` scheme and the local Mac destination.
3. Build and run. With no profile configured, the app opens in Explore Mode.
4. Choose **Add Server** and enter an HTTPS Norn URL plus a scoped access
   token. Plain HTTP is accepted only for a loopback address.

For observation, provision `api:read,events:read`. Add `platform:operate` or
`host:operate` only for Macs that should be allowed to queue those workflows.

## Verification

```sh
xcodebuild -project NornUI.xcodeproj -scheme NornUI \
  -configuration Debug -destination 'platform=macOS' \
  build CODE_SIGNING_ALLOWED=NO

xcodebuild -project NornUI.xcodeproj -scheme NornUI \
  -configuration Debug -destination 'platform=macOS' \
  test -only-testing:NornUITests CODE_SIGNING_ALLOWED=NO
```

The second command intentionally selects the unit-test target. Unsigned UI
test runners can be rejected by macOS; run the UI suite from a normally signed
Xcode build.

## Security posture

- Tokens are never persisted in preferences, request URLs, or logs.
- WebSocket authentication uses the bearer header, not a query parameter.
- Mutating work is limited to typed Norn operations and survives app/API
  restarts on the server.
- Upgrade and rollback paths require an explicit review and acknowledgement.
- Removing a server confirms before deleting both its profile and Keychain
  token.
