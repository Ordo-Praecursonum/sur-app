//
//  AttestationLiveActivityWidget.swift
//  SurLiveActivity
//
//  Renders the attestation-submission progress started by
//  AttestationActivityManager (app target) — Lock Screen banner plus
//  Dynamic Island expanded/compact/minimal presentations. This target has
//  no dependency on the app's Theme.swift (different module), so colors
//  are plain SwiftUI here rather than shared brand constants.
//

import ActivityKit
import WidgetKit
import SwiftUI

struct AttestationLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AttestationActivityAttributes.self) { context in
            LockScreenView(context: context)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: iconName(for: context.state.status))
                        .foregroundColor(color(for: context.state.status))
                }
                DynamicIslandExpandedRegion(.trailing) {
                    statusText(context.state.status)
                        .font(.caption)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.attributes.kindLabel)
                        .font(.subheadline.weight(.semibold))
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.state.detail)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            } compactLeading: {
                Image(systemName: iconName(for: context.state.status))
                    .foregroundColor(color(for: context.state.status))
            } compactTrailing: {
                if context.state.status == .submitting {
                    ProgressView()
                        .scaleEffect(0.6)
                } else {
                    Image(systemName: context.state.status == .submitted ? "checkmark" : "xmark")
                        .foregroundColor(color(for: context.state.status))
                }
            } minimal: {
                Image(systemName: iconName(for: context.state.status))
                    .foregroundColor(color(for: context.state.status))
            }
        }
    }
}

private func iconName(for status: AttestationLiveStatus) -> String {
    switch status {
    case .submitting: return "arrow.triangle.2.circlepath"
    case .submitted: return "checkmark.seal.fill"
    case .failed: return "xmark.circle.fill"
    }
}

private func color(for status: AttestationLiveStatus) -> Color {
    switch status {
    case .submitting: return .orange
    case .submitted: return .green
    case .failed: return .red
    }
}

@ViewBuilder
private func statusText(_ status: AttestationLiveStatus) -> some View {
    switch status {
    case .submitting: Text("Submitting")
    case .submitted: Text("On-chain")
    case .failed: Text("Failed")
    }
}

private struct LockScreenView: View {
    let context: ActivityViewContext<AttestationActivityAttributes>

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName(for: context.state.status))
                .font(.title2)
                .foregroundColor(color(for: context.state.status))
            VStack(alignment: .leading, spacing: 2) {
                Text(context.attributes.kindLabel)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.white)
                Text(context.state.detail)
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.7))
            }
            Spacer()
            if context.state.status == .submitting {
                ProgressView()
            }
        }
        .padding()
        .activityBackgroundTint(Color.black.opacity(0.85))
        .activitySystemActionForegroundColor(.white)
    }
}
