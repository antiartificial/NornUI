# Norn for macOS

Norn is a native control room for observing services, reviewing durable
operation receipts, and safely queuing platform or host maintenance. The app
uses Norn's versioned HTTPS and WebSocket control protocol; it does not connect
to the control-plane database or expose arbitrary shell execution.

## Current milestone

The current working milestone includes:

- A native `NavigationSplitView` shell with Overview, Apps, Operations,
  Platform, Host, and Fleet surfaces.
- Multiple Norn server profiles with scoped tokens stored device-only in
  Keychain.
- HTTPS transport, authenticated WebSocket events, persisted replay cursors,
  exponential reconnect, and authoritative refresh after reconnect.
- Durable preflight, upgrade, rollback, smoke, and host-assurance actions with
  idempotency keys and visible receipts.
- Fleet inventory, node-pool capacity planning, reconciliation checkpoints,
  GitHub review creation, and protected apply dispatch.
- A responsive provisioning view with explicit fleet checkpoint states,
  current platform/deployment execution, and an observed ingress-to-allocation
  topology assembled from Norn's fleet, deployment, health, and service
  manifest responses.
- Safe app creation with deployment disabled by default, followed by an
  explicit deployment-enable action.
- Durable app snapshots, retention pruning, exact-snapshot restore, standalone
  schema migrations, and regional application rollback. Retry-safe intents are
  retained locally until Norn accepts the operation and returns its receipt.
- Periodically refreshed host CPU, memory, storage, process, and container
  metrics when the connected server advertises that capability.
- Offline cached state, explicit request errors, fixture-backed Explore Mode,
  keyboard navigation, context menus, VoiceOver labels, semantic status, and
  Reduce Motion/Reduce Transparency support.

See [Docs/PROJECT_PLAN.md](Docs/PROJECT_PLAN.md) for the product principles,
architecture, server/client capability boundary, and remaining native-client
work.

## Run locally

1. Open `NornUI.xcodeproj` in Xcode.
2. Select the `NornUI` scheme and the local Mac destination.
3. Build and run. With no profile configured, the app opens in Explore Mode.
4. Choose **Add Server** and enter an HTTPS Norn URL plus a scoped access
   token. Plain HTTP is accepted only for a loopback address.

For observation, provision `api:read,events:read`. Add `api:write` for Macs that
may create apps, manage app recovery, or prepare and hand off fleet changes.
Add `platform:operate` or `host:operate` only for Macs that should be allowed to
queue those workflows.

## Provisioning contract boundaries

- Fleet plans and reconciliations use the versioned `/api/v1/fleet` contract.
  The Mac only offers the next GitHub handoff that the server supports: recover
  the deterministic review, then dispatch the reviewed apply. Runner phases are
  evidence-only because Norn exposes no native operator transition to advance
  or retry them.
- A successful GitHub dispatch is handoff proof only. It does not mark the
  first missing reconciliation phase active. The current contract has no
  durable runner-attempt, heartbeat, or current-phase record, so missing phases
  remain pending unless an actual queued/running operation is returned.
- Deployment history and stage checkpoints currently come from authenticated
  compatibility routes (`/api/deployments` and
  `/api/deployments/{id}/steps`). They are fetched only when the server
  advertises `regional-deployments`; failures preserve cached visibility and do
  not take the versioned control connection offline.
- The current service-manifest instance model has no region or node-pool field.
  The topology therefore shows observed ingress, desired regions/pools,
  observed allocations, and supporting platform services without claiming an
  allocation-to-pool edge the API cannot prove.

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
- App and fleet retries reuse a durable intent key until Norn acknowledges the
  request, preventing an interrupted client from creating duplicate work.
- Upgrade and rollback paths require an explicit review and acknowledgement.
- Removing a server confirms before deleting both its profile and Keychain
  token.
