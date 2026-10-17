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
    }
}
