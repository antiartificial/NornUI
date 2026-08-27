# Norn for macOS

Norn is a native control room for observing services, reviewing durable
operation receipts, and safely queuing platform or host maintenance. The app
uses Norn's versioned HTTPS and WebSocket control protocol; it does not connect
to the control-plane database or expose arbitrary shell execution.

## Current milestone

The current working milestone includes:

- A native `NavigationSplitView` shell with Overview, Apps, Activity,
  Operations, Platform, Host, and Fleet surfaces. Activity expands the sidebar
  pulse into in-flight receipts, recent operations, and service-health groups.
- Multiple Norn server profiles with native device enrollment. A per-profile
  P-256 identity is protected by Secure Enclave when available, with a
  device-only Keychain fallback; issued bearer credentials remain in Keychain.
- Ten-minute pairing codes, administrator-reviewed scopes, revocable 30-day
  device credentials, automatic renewal within seven days of expiry, and a
  manual scoped-token compatibility path.
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
- Searchable app inventory with grouped app/process/allocation disclosures,
  an optional flat presentation, active-only filtering, and sortable columns.
- Durable app snapshots, retention pruning, exact-snapshot restore, standalone
  schema migrations, and regional application rollback. Retry-safe intents are
  retained locally until Norn accepts the operation and returns its receipt.
- Periodically refreshed host CPU, memory, storage, process, and container
  metrics when the connected server advertises that capability.
- Offline cached state, explicit request errors, explicit fixture-backed previews and UI tests,
  keyboard navigation, context menus, VoiceOver labels, semantic status, and
  Reduce Motion/Reduce Transparency support.

See [Docs/PROJECT_PLAN.md](Docs/PROJECT_PLAN.md) for the product principles,
architecture, server/client capability boundary, and remaining native-client
work.

## Run locally

1. Open `NornUI.xcodeproj` in Xcode.
2. Select the `NornUI` scheme and the local Mac destination.
3. Build and run. With no profile configured, the app opens the connection
   onboarding experience.
4. Choose **Add Server**, name the server, and enter its HTTPS Norn URL. Plain
   HTTP is accepted only for a direct loopback address.
5. Review the requested permissions and choose **Start Pairing**. In an
   existing administrator session, approve the code shown by the app:

   ```sh
   norn access approve ABCD-EFGH --scope api:read,events:read
   ```

   The app exchanges the approval automatically and stores the resulting
   device credential in Keychain. The pairing code and verifier expire after
   ten minutes.

For observation, provision `api:read,events:read`. Add `api:write` for Macs that
may create apps, manage app recovery, or prepare and hand off fleet changes.
Add `platform:operate` or `host:operate` only for Macs that should be allowed to
queue those workflows. Add `fleet:operate` for fleet review/apply handoff and
`apps:exec` only when the Mac should be able to request audited terminal
sessions. An administrator may grant fewer scopes than the Mac requests and
device enrollment can never grant `admin`.

Manual token entry remains available under **Access Token** for older servers
or recovery. It is not the recommended onboarding path because a pasted token
does not receive native renewal or device-level revocation metadata.

## Provisioning contract boundaries

- Fleet plans and reconciliations use the versioned `/api/v1/fleet` contract.
  The Mac offers the next safe GitHub handoff the server supports, displays
  durable runner attempts and heartbeats, and exposes evidence-gated retry or
  advance actions when the connected principal has `fleet:operate`.
- A successful GitHub dispatch is handoff proof only. It does not mark the
  first missing reconciliation phase active. Phase state comes from Norn's
  durable runner-attempt and reconciliation evidence, never from optimistic
  client inference.
- Deployment history and stage checkpoints use authenticated versioned routes
  when advertised by `regional-deployments`; failures preserve cached
  visibility and do not take the control connection offline.
- Service-manifest instances identify observed region and node pool. The
  topology draws exact allocation edges only when Norn marks that placement as
  verified; otherwise it presents the relationship as desired or unknown.

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
- Pairing verifiers exist only in the active enrollment view and are never
  persisted. The P-256 private key never leaves Secure Enclave/Keychain APIs.
- While the app is active, managed credentials rotate automatically within
  seven days of their 30-day expiry and can be rotated manually in Settings.
  Server-side rotation revokes the prior token atomically.
- WebSocket authentication uses the bearer header, not a query parameter.
- Mutating work is limited to typed Norn operations and survives app/API
  restarts on the server.
- App and fleet retries reuse a durable intent key until Norn acknowledges the
  request, preventing an interrupted client from creating duplicate work.
- Upgrade and rollback paths require an explicit review and acknowledgement.
- Removing a server confirms before deleting its profile, Keychain token, and
  local device identity. Use `norn access revoke-device <id> --confirm` from an
  administrator session when server access must also end immediately.
