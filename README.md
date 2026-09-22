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
  idempotency keys and visible receipts. Release history leads with the
  version-first `v<major>.<minor>.<patch>-platform` label while preserving the
  exact artifact SHA for provenance and rollback.
- Fleet inventory, node-pool capacity planning, reconciliation checkpoints,
  GitHub review creation, and protected apply dispatch.
- A read-only delivery desk that treats local development as a direct lane and
  requires Fleet plus signed release evidence only for managed staging and
  production. Ordinary private repositories use `norn-signed-private`; GitHub
  Enterprise private attestations remain an optional backend.
- A responsive provisioning view with explicit fleet checkpoint states,
  current platform/deployment execution, and an observed ingress-to-allocation
  topology assembled from Norn's fleet, deployment, health, and service
  manifest responses.
- Safe app creation with deployment disabled by default, followed by an
  explicit deployment-enable action.
- Searchable app inventory with grouped app/process/allocation disclosures,
  an optional flat presentation, active-only filtering, and sortable columns.
  Recent deployments lead the default order, including apps still waiting for
  inventory. Apps and Delivery refresh while visible and show active application
  work plus a selectable graph of reported deployment steps and their timings.
  Only the selected deployment loads checkpoint detail; disconnected or old
  nonterminal records are labeled as last reported rather than live.
- Durable app snapshots, retention pruning, exact-snapshot restore, standalone
  schema migrations, and regional application rollback. Retry-safe intents are
  retained locally until Norn accepts the operation and returns its receipt.
- Host CPU, memory, storage, process, and container metrics refreshed while
  Host is visible. Recent readings appear first; the selected history window
  loads asynchronously, with per-profile persistence and optional service
  resource timelines. Chart preparation stays off the main UI thread and
  renders a bounded number of points for the visible range. Earlier/Later
  controls load adjacent ranges without a month-wide chart scroll surface.
  Drag across the plot to zoom into a range, Option-scroll to zoom around the
  pointer, or use the zoom buttons and Reset zoom. Live chart updates and
  hover details animate subtly and respect Reduce Motion.
- Configurable Overview refresh cadence, coalesced refresh requests, and
  event-cursor reconciliation when reconnecting after a retention gap.
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
queue those workflows. Human fleet planning, review, and apply handoff uses
`api:write`; `fleet:operate` is reserved for exact GitHub Actions runner
identities and must not be granted to an engineer's Mac. Add `apps:exec` only
when the Mac should be able to request audited terminal sessions. An
administrator may grant fewer scopes than the Mac requests and device
enrollment can never grant `admin`.

Manual token entry remains available under **Access Token** for older servers
or recovery. It is not the recommended onboarding path because a pasted token
does not receive native renewal or device-level revocation metadata.

Use **Manage Connections…** in the server menu to edit a saved name/address,
replace its token, test authentication, or remove the connection from this Mac.
Testing does not save changes. Saving verifies the endpoint and token before
replacing the saved connection; changing the server URL requires a newly entered
token or a new pairing. Removal does not delete a cluster or its infrastructure.

Remote servers must expose HTTPS with a trusted certificate matching the URL's
hostname. A plain HTTP API port cannot accept an HTTPS request. For private
Tailscale clusters, configure a private HTTPS proxy and permit its HTTPS port in
the tailnet policy. An SSH forward to a loopback HTTP address is also supported.
There is no certificate-verification bypass or automatic HTTP downgrade.

### Fleet Builder and connection context

The generated `cluster.yaml` preview highlights keys, strings, numbers, booleans,
and comments while preserving selectable text. The topology canvas keeps region
borders inside its padding and supports zoom buttons, actual size, Fit, and
trackpad pinch. Scrolling pans the canvas; node dragging accounts for zoom.

Managed PostgreSQL and MySQL selections are emitted directly as canonical
`managedDatabases` cluster intent. Each entry is VPC-only with TLS required;
the Builder can describe a read replica but does not create provider resources
or apply a Fleet plan.

Choose a context color beside a saved server in Manage Connections, or in its
editor. The active server menu keeps its name and a matching hue visible. Color
changes save locally without reconnecting or changing credentials.

### Connection backups and app identity

Settings → **Connection Backups** exports/imports a versioned JSON file containing
connection names, server addresses, and optional context colors. Import merges new addresses, preserves
existing connections and their credentials, and does not connect automatically.
Tokens, device keys, and enrollment metadata are never exported. Pair or enter a
token after importing a new connection.

For everyday use, run a signed build with the app sandbox entitlement. An unsigned
`CODE_SIGNING_ALLOWED=NO` build is useful for CI but reads the non-sandboxed
preferences domain, so it can appear to have no saved servers. The signed app's
connections remain in `~/Library/Containers/com.antiartificial.NornUI/Data/Library/Preferences/`.
Changing build configuration alone does not migrate or erase that store.

## Provisioning contract boundaries

- Fleet plans and reconciliations use the versioned `/api/v1/fleet` contract.
  The Mac offers the next safe GitHub handoff the server supports, displays
  durable runner attempts and heartbeats, and exposes evidence-gated retry or
  advance actions when the connected human principal has `api:write`.
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

Overview includes a bounded Happening now panel: up to three active platform operations, matching deployment step graphs, and two recent completion receipts. Live mode refreshes only the visible graphs asynchronously; manual and interval modes do not start the live activity loop. Graphs follow current progress by default and allow pausing to inspect earlier steps. Background workers without HTTP health checks use their process allocation evidence for status.

Apps also provides reviewed per-process Suspend and Resume / Scale controls for ordinary local jobs. Targets use the authenticated runtime scaling API; acceptance is shown separately from observed allocation counts, partial failures are explicit, and profile changes stop remaining requests. Counts are temporary runtime overrides and may be replaced by deployments or host assurance. Regional apps, scheduled jobs, and functions require their separate lifecycle controls.

Host history uses the authenticated retained-metrics endpoint when advertised. It loads the visible range newest-first in bounded pages, uses 15-second/minute/five-minute-or-coarser peak samples, and caches at most six pages with a 30-second live or ten-minute historical TTL. Remote chart data is freed after Host has been hidden for one minute. A subtle loading state keeps current readings available; late replies cannot cross navigation or profile boundaries. Nomad history and app overlays are kept separate from the live macOS collector, and servers without the endpoint retain the local-history fallback.
