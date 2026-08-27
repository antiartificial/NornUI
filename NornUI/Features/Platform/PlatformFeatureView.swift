//
//  PlatformFeatureView.swift
//  NornUI
//
//  A deliberately calm release desk: operators see the plan before Norn queues work.
//

import AppKit
import SwiftUI

struct PlatformFeatureView: View {
    fileprivate enum PendingAction: Identifiable, Equatable {
        case preflight(ref: String)
        case upgrade(ref: String, mode: String, drainMode: String)
        case rollback(release: NornRelease)
        case smoke

        var id: String {
            switch self {
            case let .preflight(ref): "preflight-\(ref)"
            case let .upgrade(ref, mode, drainMode): "upgrade-\(ref)-\(mode)-\(drainMode)"
            case let .rollback(release): "rollback-\(release.sha)"
            case .smoke: "smoke"
            }
        }

        var title: String {
            switch self {
            case .preflight: "Queue preflight"
            case .upgrade: "Queue platform upgrade"
            case .rollback: "Queue rollback"
            case .smoke: "Queue smoke check"
            }
        }

        var request: NornMaintenanceRequest {
            switch self {
            case let .preflight(ref): .platformPreflight(ref: ref)
            case let .upgrade(ref, mode, drainMode): .platformUpgrade(ref: ref, mode: mode, drainMode: drainMode)
            case let .rollback(release): .platformRollback(sha: release.sha)
            case .smoke: .platformSmoke
            }
        }

        var risk: String {
            switch self {
            case .preflight, .smoke:
                "Read-only verification. Norn records a durable receipt without changing the active release."
            case .upgrade:
                "Changes the active platform release. Norn drains work according to the selected policy and keeps the receipt alive through restart."
            case .rollback:
                "Restores a prior platform release. Running services will restart during the handoff."
            }
        }

        var requiresAcknowledgement: Bool {
            switch self {
            case .upgrade, .rollback: true
            case .preflight, .smoke: false
            }
        }

        var symbol: String {
            switch self {
            case .preflight: "checklist"
            case .upgrade: "arrow.up.forward.app"
            case .rollback: "arrow.uturn.backward.circle"
            case .smoke: "aqi.medium"
            }
        }
    }

    let releases: [NornRelease]
    let activeOperations: [NornOperation]
    let isConnected: Bool
    var onQueue: (NornMaintenanceRequest) -> Void = { _ in }
    var onCopyRelease: (NornRelease) -> Void = { _ in }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var reference = "main"
    @State private var upgradeMode = "restart"
    @State private var drainMode = "wait"
    @State private var selectedReleaseID: String?
    @State private var pendingAction: PendingAction?
    @State private var acknowledgement = false

    init(
        snapshot: NornDashboardSnapshot,
        isConnected: Bool = true,
        onQueue: @escaping (NornMaintenanceRequest) -> Void = { _ in },
        onCopyRelease: @escaping (NornRelease) -> Void = { _ in }
    ) {
        self.releases = snapshot.releases.sorted { $0.createdAt > $1.createdAt }
        self.activeOperations = snapshot.activeOperations
        self.isConnected = isConnected
        self.onQueue = onQueue
        self.onCopyRelease = onCopyRelease
        _selectedReleaseID = State(initialValue: snapshot.releases.first(where: \.current)?.id)
    }

    init(
        releases: [NornRelease],
        activeOperations: [NornOperation] = [],
        isConnected: Bool = true,
        onQueue: @escaping (NornMaintenanceRequest) -> Void = { _ in },
        onCopyRelease: @escaping (NornRelease) -> Void = { _ in }
    ) {
        self.releases = releases.sorted { $0.createdAt > $1.createdAt }
        self.activeOperations = activeOperations
        self.isConnected = isConnected
        self.onQueue = onQueue
        self.onCopyRelease = onCopyRelease
        _selectedReleaseID = State(initialValue: releases.first(where: \.current)?.id)
    }

    private var currentRelease: NornRelease? { releases.first(where: \.current) }
    private var selectedRelease: NornRelease? { releases.first { $0.id == selectedReleaseID } }
    private var isPlatformBusy: Bool {
        activeOperations.contains { $0.kind.hasPrefix("platform.") && $0.status.isActive }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                releaseHeader

                if !isConnected {
                    offlineNotice
                } else if isPlatformBusy {
                    activeOperationNotice
                }

                HStack(alignment: .top, spacing: 18) {
                    upgradeComposer
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    releaseHistory
                        .frame(minWidth: 300, idealWidth: 390, maxWidth: 450)
                }

                if let pendingAction {
                    ActionReviewCard(
                        action: pendingAction,
                        acknowledgement: $acknowledgement,
                        isConnected: isConnected,
                        isPlatformBusy: isPlatformBusy,
                        onCancel: clearPendingAction,
                        onConfirm: queuePendingAction
                    )
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                }
            }
            .padding(20)
            .frame(maxWidth: 1_250, alignment: .leading)
        }
        .navigationTitle("Releases")
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: pendingAction)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: isPlatformBusy)
    }

    private var releaseHeader: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: "shippingbox.and.arrow.forward")
                .font(.title2)
                .foregroundStyle(.tint)
                .symbolRenderingMode(.hierarchical)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text("Platform releases")
                    .font(.title2.weight(.semibold))
                if let currentRelease {
                    Text("Current: \(currentRelease.displayLabel(in: releases)) · \(currentRelease.shortSHA)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Text("No active release receipt is available.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Button("Run Smoke Check") { stage(.smoke) }
                .buttonStyle(.bordered)
                .disabled(!isConnected || isPlatformBusy)
                .accessibilityHint("Queues a read-only platform smoke check")
        }
    }

    private var offlineNotice: some View {
        Label("Reconnect to queue maintenance. Release history remains visible from the last observation.", systemImage: "wifi.slash")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .accessibilityLabel("Offline. Queued release actions are unavailable.")
    }

    private var activeOperationNotice: some View {
        Label("A platform operation is in progress. Norn serializes release changes; review its receipt before queuing another.", systemImage: "lock.fill")
            .font(.subheadline)
            .foregroundStyle(.orange)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .accessibilityLabel("Platform maintenance is already in progress")
    }

    private var upgradeComposer: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Prepare an upgrade", systemImage: "arrow.up.forward.app")
                .font(.headline)

            Text("Every change is queued as a durable Norn operation. Review the plan before it is sent.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 12) {
                GridRow {
                    Text("Reference")
                        .foregroundStyle(.secondary)
                    TextField("Git SHA, tag, or branch", text: $reference)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Release reference")
                }
                GridRow {
                    Text("Handoff")
                        .foregroundStyle(.secondary)
                    Picker("Handoff", selection: $upgradeMode) {
                        Text("Restart").tag("restart")
                        Text("Proxy cutover").tag("proxy")
                    }
                    .pickerStyle(.segmented)
                    .accessibilityHint("Restart is the safest default; proxy cutover requires a healthy proxy path")
                }
                GridRow {
                    Text("Drain")
                        .foregroundStyle(.secondary)
                    Picker("Drain", selection: $drainMode) {
                        Text("Wait").tag("wait")
                        Text("Fail if busy").tag("fail")
                        Text("Force").tag("force")
                    }
                    .pickerStyle(.segmented)
                    .accessibilityHint("Wait lets active work finish. Force interrupts active work.")
                }
            }

            HStack(spacing: 10) {
                Button("Review Preflight") {
                    stage(.preflight(ref: normalizedReference))
                }
                .buttonStyle(.bordered)
                .disabled(!canStageReferenceAction)

                Button("Review Upgrade") {
                    stage(.upgrade(ref: normalizedReference, mode: upgradeMode, drainMode: drainMode))
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canStageReferenceAction)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var releaseHistory: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Release history", systemImage: "clock.arrow.circlepath")
                .font(.headline)

            if releases.isEmpty {
                ContentUnavailableView("No releases", systemImage: "shippingbox")
                    .frame(minHeight: 180)
            } else {
                List(selection: $selectedReleaseID) {
                    ForEach(releases) { release in
                        ReleaseRow(
                            release: release,
                            displayLabel: release.displayLabel(in: releases)
                        )
                            .tag(release.id)
                            .contextMenu {
                                Button("Copy SHA") { copyRelease(release) }
                                if !release.current {
                                    Divider()
                                    Button("Review Rollback to This Release", role: .destructive) {
                                        stage(.rollback(release: release))
                                    }
                                    .disabled(!isConnected || isPlatformBusy)
                                }
                            }
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
                .frame(minHeight: 210, idealHeight: 270)
                .accessibilityLabel("Platform release history")
            }

            if let selectedRelease, !selectedRelease.current {
                Button("Review Rollback") { stage(.rollback(release: selectedRelease)) }
                    .buttonStyle(.bordered)
                    .disabled(!isConnected || isPlatformBusy)
                    .accessibilityHint("Shows the impact before a rollback is queued")
            }
        }
        .padding(18)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var normalizedReference: String { reference.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canStageReferenceAction: Bool { isConnected && !isPlatformBusy && !normalizedReference.isEmpty }

    private func stage(_ action: PendingAction) {
        acknowledgement = false
        pendingAction = action
    }

    private func clearPendingAction() {
        acknowledgement = false
        pendingAction = nil
    }

    private func queuePendingAction() {
        guard let pendingAction else { return }
        onQueue(pendingAction.request)
        clearPendingAction()
    }

    private func copyRelease(_ release: NornRelease) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(release.sha, forType: .string)
        onCopyRelease(release)
    }
}

private struct ReleaseRow: View {
    let release: NornRelease
    let displayLabel: String

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: release.current ? "checkmark.seal.fill" : "shippingbox")
                .foregroundStyle(release.current ? .green : .secondary)
                .symbolRenderingMode(.hierarchical)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(displayLabel)
                        .font(.body.weight(.medium))
                    if release.current {
                        Text("CURRENT")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.green)
                    }
                }
                Text("SHA \(release.shortSHA) · \(release.createdAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(release.current ? "Current " : "")release \(displayLabel), artifact SHA \(release.sha)")
        .help("Artifact SHA: \(release.sha)\nPath: \(release.path)")
    }
}

private struct ActionReviewCard: View {
    let action: PlatformFeatureView.PendingAction
    @Binding var acknowledgement: Bool
    let isConnected: Bool
    let isPlatformBusy: Bool
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                Image(systemName: action.symbol)
                    .font(.title3)
                    .foregroundStyle(action.requiresAcknowledgement ? .orange : .accentColor)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(action.title)
                        .font(.headline)
                    Text(action.risk)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(action.requiresAcknowledgement ? "Change" : "Verification")
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.quaternary, in: Capsule())
            }

            if action.requiresAcknowledgement {
                Toggle("I understand that Norn will perform this platform change independently of this window.", isOn: $acknowledgement)
                    .toggleStyle(.checkbox)
                    .accessibilityHint("Required before the action can be queued")
            }

            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(action.title, action: onConfirm)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isConnected || isPlatformBusy || (action.requiresAcknowledgement && !acknowledgement))
                    .accessibilityHint("Queues a durable Norn operation")
            }
        }
        .padding(18)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(action.requiresAcknowledgement ? Color.orange.opacity(0.35) : Color.accentColor.opacity(0.25))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Action review: \(action.title)")
    }
}

#Preview("Release Desk") {
    PlatformFeatureView(snapshot: NornFixtures.snapshot)
        .frame(width: 1_100, height: 760)
}

#Preview("Release Desk Offline") {
    PlatformFeatureView(snapshot: NornFixtures.snapshot, isConnected: false)
        .frame(width: 1_100, height: 760)
}
