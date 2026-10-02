import SwiftUI

/// Shared "report this person" form used from both Settings and the snap viewer.
/// Collects a reason and optional detail, and — on surfaces where the user can't
/// otherwise reach the block action (the viewer) — an optional "block them too"
/// toggle. The caller performs the actual report/block calls.
struct ReportSheet: View {
    /// Name used in copy; falls back to a neutral phrase.
    var subjectName = "this person"
    /// Whether to offer a "Block … too" toggle alongside the report.
    var showsBlockOption = false
    /// Called on Submit with the chosen reason, the detail text, and whether the
    /// user also asked to block. `alsoBlock` is always false when
    /// `showsBlockOption` is false.
    let onSubmit: (_ reason: String, _ detail: String, _ alsoBlock: Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var reason = ReportReason.harassment
    @State private var detail = ""
    @State private var alsoBlock = true

    enum ReportReason: String, CaseIterable, Identifiable {
        case harassment = "Harassment"
        case nudity = "Unwanted nudity"
        case impersonation = "Impersonation"
        case other = "Other"
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker("Reason", selection: $reason) {
                    ForEach(ReportReason.allCases) { Text($0.rawValue).tag($0) }
                }
                Section("Details (optional)") {
                    TextField("Add anything that helps", text: $detail, axis: .vertical)
                        .lineLimit(3...6)
                }
                if showsBlockOption {
                    Section {
                        Toggle("Block \(subjectName) too", isOn: $alsoBlock)
                    } footer: {
                        Text("Blocking ends your pair, deletes all shared snaps, and permanently prevents pairing.")
                    }
                }
            }
            .navigationTitle("Report")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Submit") {
                        onSubmit(reason.rawValue, detail, showsBlockOption && alsoBlock)
                    }
                }
            }
        }
    }
}
