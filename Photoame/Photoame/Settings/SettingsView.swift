import SwiftUI
import PhotosUI

struct SettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var model: SettingsViewModel?

    @State private var confirmEndPair = false
    @State private var confirmBlock = false
    @State private var confirmDelete = false
    @State private var showReport = false
    @State private var pickedAvatar: PhotosPickerItem?

    #if DEBUG
    // Pending backend choice (persisted; applies on next launch).
    @State private var useProductionBackend = FirebaseConfig.useProduction
    @State private var backendChanged = false
    #endif

    private let privacyURL = URL(string: "https://photoame.com/privacy/")!
    private let supportURL = URL(string: "https://photoame.com/support/")!

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
            Section("Your profile") {
                HStack(spacing: 16) {
                    ZStack {
                        AvatarView(url: model.ownPhotoURL, name: model.displayName, size: 64)
                        if model.uploadingAvatar {
                            Circle().fill(.black.opacity(0.4)).frame(width: 64, height: 64)
                            ProgressView().controlSize(.small).tint(.white)
                        }
                    }
                    PhotosPicker(selection: $pickedAvatar, matching: .images) {
                        Text(model.ownPhotoURL == nil ? "Add photo" : "Change photo")
                    }
                    .disabled(model.uploadingAvatar)
                }
                TextField("Display name", text: $model.displayName)
                    .onSubmit { model.saveDisplayName() }
                Button("Save name") { model.saveDisplayName() }
            }

            if model.isPaired {
                Section("Partner") {
                    HStack(spacing: 12) {
                        AvatarView(url: model.partnerPhotoURL, name: model.partnerName, size: 40)
                        Text(model.partnerName)
                    }
                }

                Section("Safety") {
                    Button("End pair", role: .destructive) { confirmEndPair = true }
                    Button("Block \(model.partnerName)", role: .destructive) { confirmBlock = true }
                    Button("Report \(model.partnerName)") { showReport = true }
                }
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
            ReportSheet(subjectName: model.partnerName) { reason, detail, _ in
                model.report(reason: reason, detail: detail)
                showReport = false
            }
        }
        .alert("Something went wrong",
               isPresented: .init(get: { model.errorMessage != nil },
                                  set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(model.errorMessage ?? "") }
        .onChange(of: pickedAvatar) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    model.updateAvatar(imageData: data)
                }
                pickedAvatar = nil
            }
        }
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
