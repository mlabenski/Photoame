import SwiftUI

struct SettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var model: SettingsViewModel?

    @State private var confirmEndPair = false
    @State private var confirmBlock = false
    @State private var confirmDelete = false
    @State private var showReport = false

    #if DEBUG
    // Pending backend choice (persisted; applies on next launch).
    @State private var useProductionBackend = FirebaseConfig.useProduction
    @State private var backendChanged = false
    #endif

    // Placeholder URLs (see README).
    private let privacyURL = URL(string: "https://photoame.example.com/privacy")!
    private let supportURL = URL(string: "https://photoame.example.com/support")!

    var body: some View {
        NavigationStack {
            Group {
                if let model { form(model) }
                else { ProgressView() }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                if model == nil {
                    let vm = SettingsViewModel(auth: env.auth, functions: env.functions)
                    vm.load()
                    model = vm
                }
            }
        }
    }

    private func form(_ model: SettingsViewModel) -> some View {
        @Bindable var model = model
        return Form {
            Section("Your name") {
                TextField("Display name", text: $model.displayName)
                    .onSubmit { model.saveDisplayName() }
                Button("Save name") { model.saveDisplayName() }
            }

            Section("Partner") {
                LabeledContent("Paired with", value: model.partnerName)
            }

            Section("Safety") {
                Button("End pair", role: .destructive) { confirmEndPair = true }
                Button("Block \(model.partnerName)", role: .destructive) { confirmBlock = true }
                Button("Report \(model.partnerName)") { showReport = true }
            }

            Section {
                Link("Privacy policy", destination: privacyURL)
                Link("Support", destination: supportURL)
            }

            Section {
                Button("Sign out") { model.signOut() }
                Button("Delete account", role: .destructive) { confirmDelete = true }
            } footer: {
                Text("Deleting your account ends your pair and permanently removes all of your data.")
            }

            #if DEBUG
            developerSection
            #endif
        }
        .confirmationDialog("End your pair?", isPresented: $confirmEndPair, titleVisibility: .visible) {
            Button("End pair", role: .destructive) { model.endPair(); dismiss() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All snaps for both of you are deleted. You can't re-pair with each other for 24 hours.")
        }
        .confirmationDialog("Block \(model.partnerName)?", isPresented: $confirmBlock, titleVisibility: .visible) {
            Button("Block", role: .destructive) { model.block(); dismiss() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This ends your pair, deletes all shared snaps, and permanently prevents pairing.")
        }
        .confirmationDialog("Delete your account?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete everything", role: .destructive) { model.deleteAccount() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cannot be undone.")
        }
        .sheet(isPresented: $showReport) {
            ReportSheet { reason, detail in
                model.report(reason: reason, detail: detail)
                showReport = false
            }
        }
        .alert("Something went wrong",
               isPresented: .init(get: { model.errorMessage != nil },
                                  set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(model.errorMessage ?? "") }
    }

    #if DEBUG
    @ViewBuilder
    private var developerSection: some View {
        Section {
            Toggle("Use production backend", isOn: Binding(
                get: { useProductionBackend },
                set: { newValue in
                    useProductionBackend = newValue
                    FirebaseConfig.setUseProduction(newValue)
                    backendChanged = (newValue != FirebaseConfig.activeIsProduction)
                }))
            LabeledContent("This session", value: FirebaseConfig.activeBackendDescription)
        } header: {
            Text("Developer")
        } footer: {
            Text(backendChanged
                 ? "Quit and reopen the app to switch backends. You'll be signed out (the session belongs to the other backend)."
                 : "The emulator can't deliver push notifications. Switch to production to test them on a device. This choice survives app relaunches.")
        }
    }
    #endif
}

/// Collect a report reason + optional detail.
private struct ReportSheet: View {
    let onSubmit: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var reason = ReportReason.harassment
    @State private var detail = ""

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
            }
            .navigationTitle("Report")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Submit") { onSubmit(reason.rawValue, detail) }
                }
            }
        }
    }
}
