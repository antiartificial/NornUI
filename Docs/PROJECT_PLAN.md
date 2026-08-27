# Norn for macOS — Product Plan

## Product promise

Norn is a calm, trustworthy control room for the services you own. It should
make complex platform work legible, preserve the operator's sense of control,
and make healthy systems feel quietly alive.

The app uses HTTPS for queries and commands, the authenticated v1 WebSocket
for durable event replay, and the Norn operation queue for work that must
survive an API restart. It never connects directly to the control-plane
database or executes arbitrary host shell commands.

## Milestone 1 — Native control room

**Status: working foundation delivered.** The app builds, the unit suite passes,
and the fixture-backed experience has been visually verified at the default and
minimum window sizes. Live-server acceptance remains a deployment step because
the repository intentionally contains no server address or credential.

- Multiple server profiles with native pairing, Secure Enclave/Keychain device
  identities, Keychain-backed credentials, renewal, and manual-token fallback.
- Capability negotiation and explicit connection state.
- Fleet overview backed by health, service manifest, releases, and operations.
- Fleet inventory, capacity plans, reconciliation checkpoints, GitHub review,
  and protected apply handoff.
- Safe app creation, explicit deployment enablement, snapshots, retention
  pruning, exact-snapshot restore, standalone migrations, and regional
  application rollback.
- Host CPU, memory, storage, process, and container metrics with periodic
  refresh while the Host surface is visible.
- Operations timeline with durable status and receipts.
- Platform release, preflight, upgrade, rollback, smoke, and host-assurance
  workflows using the versioned control protocol.
- Cursor-persisted event reconnect and state reconciliation.
- A rich, explicitly enabled fixture mode for previews and UI tests; normal
  launches without a server show onboarding rather than sample history.
- Native menus, keyboard commands, resizable windows, reduced-motion support,
  VoiceOver descriptions, and semantic light/dark materials.

## Experience principles

1. **Alive, not noisy.** Motion communicates state change. It never loops merely
   to decorate the screen and it respects Reduce Motion.
2. **Receipts over spinners.** Server operations continue independently of the
   window. The UI always exposes the operation ID, stage, timing, and result.
3. **Risk is visible before action.** Read-only actions are direct. Mutating or
   disruptive work has a concise plan and confirmation.
4. **Offline is a state, not an error screen.** Last-known data remains visible
   with its observation time; mutations are disabled until authority returns.
5. **Mac first.** Sidebar navigation, tables, inspectors, contextual menus,
   keyboard equivalents, multiple windows, and standard titlebar behavior.

## Architecture

- `Core/Models`: wire-compatible, Sendable Norn domain models.
- `Core/Networking`: actor-isolated HTTP and WebSocket transports.
- `Core/Security`: Keychain credential storage.
- `App`: profile selection, orchestration, reconciliation, and navigation.
- `DesignSystem`: semantic status, cards, motion, empty/error states, and icons.
- `Features`: Overview, Apps, Operations, Platform, Host, Fleet, and Settings.

## Parallel ownership

- **Transport lane:** networking, WebSocket replay, Keychain, and contract tests.
- **Experience lane:** design tokens, motion primitives, reusable components,
  and the overview surface.
- **Operations lane:** operation timeline and platform/host workflows.
- **Orchestrator lane:** shared models, app state, navigation shell, settings,
  menus, integration, accessibility, and end-to-end verification.

## Server capabilities and native-client work

Norn's server contract continues to advance. Device onboarding is now a
first-class Mac experience; the remaining items below are server-supported
capabilities that still need broader native presentation:

- **Device onboarding — delivered:** pairing is the default Add Server path.
  The app creates a P-256 identity in Secure Enclave or a device-only Keychain
  fallback, keeps the pairing verifier in memory, polls for administrator
  approval, stores the one-time bearer in Keychain, and rotates it while active
  within seven days of its 30-day expiry. Settings exposes granted scopes,
  expiry, manual rotation, migration from a pasted token, and local removal.
  Server-wide device inventory and revocation remain administrator CLI/API
  actions.
- **Typed failures and receipts:** the server publishes stable problem codes,
  stronger operation receipts, and explicit operation-cancellation semantics.
  The app currently preserves safe error text and request IDs, and strongly
  models the workflows it exposes; it does not yet present the complete typed
  problem, receipt, or cancellation vocabulary.
- **Event continuity:** the server publishes retention bounds, oldest/latest
  cursors, heartbeat and gap signals, and subscription filters. The app
  currently persists a replay cursor, reconnects exponentially, and performs an
  authoritative refresh, but it does not yet expose filter controls or explicit
  retention-gap recovery UI.
- **Exec sessions:** the server offers framed stdout, stderr, input, resize,
  exit, expiry, audit, cancellation, and explicit step-up authorization. The Mac
  app intentionally exposes no terminal until a native session, approval, and
  audit experience is designed and reviewed.

An optional same-host XPC recovery helper remains a future architecture option.
If introduced, it must be limited to narrowly defined bootstrap actions and
must not become an arbitrary privileged shell.
