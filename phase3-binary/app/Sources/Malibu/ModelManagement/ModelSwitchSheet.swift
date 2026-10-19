import SwiftUI

/// Switch confirmation and progress (SPEC-011 warm swap). The copy states the
/// customer impact and that a switch cannot be cancelled once it starts.
enum SwitchSheetPresentation {
    enum Stage: Equatable {
        case confirm
        case running(phase: String, elapsedSeconds: Int)
        case reconciling
        case succeeded
        case failed(String)
    }

    static let steps = ["requested", "loading", "draining", "loaded"]

    static let notStarted = String(localized: "Nothing changed: the provider's model controls were not ready or the model catalog changed since this opened. Review Models and try again.", comment: "Switch did not start")

    static func stepTitle(_ phase: String) -> String {
        switch phase {
        case "requested": return String(localized: "Switch requested", comment: "Switch progress step")
        case "loading": return String(localized: "Loading the new model (customers get \"provider loading\")", comment: "Switch progress step")
        case "draining": return String(localized: "Finishing requests already running", comment: "Switch progress step")
        default: return String(localized: "Switched", comment: "Switch progress step")
        }
    }

    static func confirmTitle(target: String, isRevert: Bool) -> String {
        isRevert
            ? String(localized: "Revert to \(target)?", comment: "Switch sheet title for revert")
            : String(localized: "Switch to \(target)?", comment: "Switch sheet title")
    }

    static func confirmLines(row: MalibuModelRow, currentModelID: String?, allRows: [MalibuModelRow]) -> [String] {
        var lines = [
            String(localized: "From \(currentModelID.map { ShellText.display($0) } ?? "the current model") to \(ModelsPresentation.name(row)).", comment: "Switch sheet transition"),
            String(localized: "Customers get a \"provider loading\" response (HTTP 503) while the new model loads and requests already running finish. Switching can't be cancelled once it starts.", comment: "Switch sheet customer impact"),
            String(localized: "The weights are already on this Mac; nothing is downloaded. If loading fails, this Mac keeps serving the current model.", comment: "Switch sheet local-only note"),
        ]
        if let economics = ModelsPresentation.rateAndDemand(row, allRows: allRows) {
            lines.append(economics)
            if let caveat = row.nonEarningDisclosure { lines.append(caveat) }
            lines.append(ModelsPresentation.rateDisclosure)
        }
        return lines
    }

    /// The sheet stage from the store operation after the provider confirmed
    /// the switch request.
    static func stage(
        operation: ModelManagementStore.Operation,
        target: String,
        currentModelID: String?,
        statusLine: String,
        observedStart: Bool = true
    ) -> Stage {
        // Until the store reports this switch, an earlier failure or cooldown
        // must not read as this switch's outcome.
        guard observedStart else { return .running(phase: "requested", elapsedSeconds: 0) }
        switch operation {
        case .switching(let operationTarget, let phase, let elapsedMS) where operationTarget == target:
            if phase == "failed" { return .failed(statusLine) }
            return .running(phase: phase, elapsedSeconds: elapsedMS / 1_000)
        case .reconciling(let operationTarget) where operationTarget == target:
            return .reconciling
        case .runtimeConflict, .failed, .cooldown:
            return .failed(statusLine)
        default:
            if let currentModelID,
               ModelManagementStore.recommendationTargetIsCurrent(target, currentModelID: currentModelID) {
                return .succeeded
            }
            return .running(phase: "requested", elapsedSeconds: 0)
        }
    }

    static func stageLine(_ stage: Stage) -> String {
        switch stage {
        case .confirm:
            return ""
        case .running(let phase, let seconds):
            return "\(stepTitle(phase)) · \(seconds) s"
        case .reconciling:
            return String(localized: "Confirming the provider loaded the new model…", comment: "Switch progress reconciling")
        case .succeeded:
            return String(localized: "Switched. This Mac now serves the new model.", comment: "Switch progress success")
        case .failed(let reason):
            return String(localized: "Switch did not complete: \(reason) This Mac keeps serving the model it reports.", comment: "Switch progress failure")
        }
    }
}

/// Confirm, then follow the switch until the provider confirms or refuses it.
struct ModelSwitchSheet: View {
    @ObservedObject var store: ModelManagementStore
    let row: MalibuModelRow
    let isRevert: Bool
    let onClose: () -> Void
    @State private var started = false
    @State private var observedStart = false
    @State private var refusedToStart = false

    private var stage: SwitchSheetPresentation.Stage {
        guard started else { return .confirm }
        if refusedToStart { return .failed(SwitchSheetPresentation.notStarted) }
        return SwitchSheetPresentation.stage(
            operation: store.operation,
            target: row.id,
            currentModelID: store.currentModelID,
            statusLine: store.statusLine,
            observedStart: observedStart
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(SwitchSheetPresentation.confirmTitle(target: ModelsPresentation.name(row), isRevert: isRevert))
                .font(.title3.weight(.semibold))
                .lineLimit(2)
                .truncationMode(.middle)
            switch stage {
            case .confirm:
                ForEach(Array(SwitchSheetPresentation.confirmLines(
                    row: row,
                    currentModelID: store.currentModelID,
                    allRows: store.rows
                ).enumerated()), id: \.offset) { index, line in
                    Text(line)
                        .font(index == 1 ? .callout.weight(.semibold) : .callout)
                        .foregroundStyle(index == 1 ? Color.primary : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Spacer()
                    Button(String(localized: "Cancel", comment: "Switch confirmation cancel"), role: .cancel, action: onClose)
                        .keyboardShortcut(.cancelAction)
                    Button(isRevert
                           ? String(localized: "Revert", comment: "Model feature action")
                           : String(localized: "Switch", comment: "Model feature action")) {
                        started = true
                        Task {
                            let didStart = await store.switchTo(row, operationName: isRevert ? "revert" : "switch")
                            if !didStart { refusedToStart = true }
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!store.canPerformModelAction)
                }
            default:
                progress
                HStack {
                    Spacer()
                    if !isTerminal {
                        Text(String(localized: "Closing this sheet does not stop the switch.", comment: "Switch sheet close note"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button(String(localized: "Close", comment: "Model feature dismiss button"), action: onClose)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 480)
        .onChange(of: store.operation) { _, operation in
            guard started else { return }
            switch operation {
            case .switching(let target, _, _), .reconciling(let target):
                if target == row.id { observedStart = true }
            default:
                break
            }
        }
        .accessibilityIdentifier("malibu.models.switch-sheet")
    }

    private var isTerminal: Bool {
        switch stage {
        case .succeeded, .failed: return true
        default: return false
        }
    }

    private var progress: some View {
        let current = stage
        let activeIndex: Int
        switch current {
        case .running(let phase, _): activeIndex = SwitchSheetPresentation.steps.firstIndex(of: phase) ?? 0
        case .reconciling, .succeeded: activeIndex = SwitchSheetPresentation.steps.count
        default: activeIndex = -1
        }
        return VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(SwitchSheetPresentation.steps.enumerated()), id: \.offset) { index, phase in
                HStack(spacing: 8) {
                    Image(systemName: index < activeIndex ? "checkmark.circle.fill" : (index == activeIndex ? "circle.dotted" : "circle"))
                        .foregroundStyle(index <= activeIndex ? Color.accentColor : Color.secondary)
                        .accessibilityHidden(true)
                    Text(SwitchSheetPresentation.stepTitle(phase))
                        .font(.callout)
                        .foregroundStyle(index <= activeIndex ? Color.primary : Color.secondary)
                }
            }
            Text(SwitchSheetPresentation.stageLine(current))
                .font(.callout)
                .foregroundStyle({ if case .failed = current { return Color.red } else { return Color.secondary } }())
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.updatesFrequently)
            if case .running = current {
                ProgressView().controlSize(.small)
            }
        }
    }
}
