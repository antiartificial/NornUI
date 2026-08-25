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

- Multiple server profiles with Keychain-backed scoped tokens.
- Capability negotiation and explicit connection state.
- Fleet overview backed by health, service manifest, releases, and operations.
- Operations timeline with durable status and receipts.
- Platform release, preflight, upgrade, rollback, smoke, and host-assurance
  workflows using the versioned control protocol.
- Cursor-persisted event reconnect and state reconciliation.
- A rich fixture mode for previews, UI tests, and offline exploration.
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
- `Features`: Overview, Operations, Platform, Host, Apps, and Settings.

## Parallel ownership

- **Transport lane:** networking, WebSocket replay, Keychain, and contract tests.
- **Experience lane:** design tokens, motion primitives, reusable components,
  and the overview surface.
- **Operations lane:** operation timeline and platform/host workflows.
- **Orchestrator lane:** shared models, app state, navigation shell, settings,
  menus, integration, accessibility, and end-to-end verification.

## Later protocol milestones

- Pairing, refresh, revocation, and device management instead of manually
  provisioning a long-lived administrative credential.
- Standard problem details and typed operation receipts.
- Event stream heartbeat, retention bounds, gap signaling, and subscriptions.
- A formal exec-session protocol with resize, exit, audit, and step-up auth.
- Optional same-host XPC recovery helper, strictly limited to bootstrap actions.
