import SwiftUI

struct HostListView: View {
    let model: AppModel

    var body: some View {
        NavigationStack {
            List {
                Section("同じネットワークの Mac") {
                    ForEach(model.hosts) { host in
                        Button {
                            model.select(host)
                        } label: {
                            Label(host.name, systemImage: "laptopcomputer")
                        }
                    }
                }
            }
            .overlay {
                if model.isLocalNetworkDenied {
                    ContentUnavailableView {
                        Label("ローカルネットワークを使えません", systemImage: "network.slash")
                    } description: {
                        Text("Mac を探すには、iPad の設定で PadBridge に「ローカルネットワーク」の許可が要ります。")
                    } actions: {
                        Button("設定を開く") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                    }
                } else if model.hosts.isEmpty {
                    ContentUnavailableView(
                        "Mac が見つかりません",
                        systemImage: "laptopcomputer.slash",
                        description: Text("Mac で PadBridge Host を起動し、この iPad と同じネットワークにつないでください。")
                    )
                }
            }
            .navigationTitle("PadBridge")
        }
    }
}
