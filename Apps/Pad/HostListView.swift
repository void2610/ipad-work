import SwiftUI

struct HostListView: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationStack {
            List {
                if let error = model.errorMessage {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
                Section("同じネットワークの Mac") {
                    ForEach(model.hosts) { host in
                        Button {
                            model.select(host)
                        } label: {
                            Label(host.name, systemImage: "laptopcomputer")
                        }
                        .swipeActions {
                            Button("ペアリング解除", role: .destructive) {
                                model.forgetPairing(for: host)
                            }
                        }
                    }
                }
            }
            .overlay {
                if model.hosts.isEmpty {
                    ContentUnavailableView(
                        "Mac が見つかりません",
                        systemImage: "laptopcomputer.slash",
                        description: Text("Mac で PadBridge Host を起動し、この iPad と同じネットワークにつないでください。")
                    )
                }
            }
            .navigationTitle("PadBridge")
        }
        .sheet(item: $model.pairingTarget) { host in
            PairingCodeView(
                host: host,
                error: model.pairingError,
                onSubmit: { model.submitPairingCode($0, for: host) },
                onCancel: model.cancelPairing
            )
        }
    }
}

private struct PairingCodeView: View {
    let host: DiscoveredHost
    let error: String?
    let onSubmit: (String) -> Void
    let onCancel: () -> Void
    @State private var code = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("ABCDE-FGHJK", text: $code)
                        .font(.system(.title2, design: .monospaced))
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .focused($isFocused)
                        .onSubmit { onSubmit(code) }
                } header: {
                    Text("\(host.name) のペアリングコード")
                } footer: {
                    Text(error ?? "Mac のメニューバーにある PadBridge のアイコンを押すと表示されます。")
                        .foregroundStyle(error == nil ? Color.secondary : Color.orange)
                }
            }
            .navigationTitle("ペアリング")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("接続") { onSubmit(code) }
                }
            }
            .onAppear { isFocused = true }
        }
    }
}
