import ChromiumKit
import SwiftUI

struct ContentView: View {
    @Bindable var session: Session
    @Environment(TabRuntime.self) private var runtime

    var body: some View {
        NavigationSplitView {
            List(selection: $session.selectedTabID) {
                ForEach(session.orderedTabs) { tab in
                    TabRow(tab: tab).tag(tab.id)
                }
            }
            .navigationTitle("Tabs")
            .toolbar {
                ToolbarItem {
                    Button { runtime.newTab(in: session) } label: { Image(systemName: "plus") }
                        .help("New tab")
                        .accessibilityIdentifier("newTabButton")
                }
            }
            .frame(minWidth: 220)
        } detail: {
            VStack(spacing: 0) {
                AddressBar(tab: selectedTab)
                ZStack {
                    ForEach(session.orderedTabs) { tab in
                        if let webView = runtime.liveWebView(for: tab) {
                            ChromiumWebViewRepresentable(webView)
                                .opacity(tab.id == session.selectedTabID ? 1 : 0)
                                .allowsHitTesting(tab.id == session.selectedTabID)
                        }
                    }
                }
            }
        }
        .onAppear { wakeSelected() }
        .onChange(of: session.selectedTabID) { wakeSelected() }
    }

    private var selectedTab: TabRecord? {
        session.orderedTabs.first { $0.id == session.selectedTabID }
    }

    /// Wake the selected tab here (an action), not in `body`, so we never mutate
    /// the runtime registry mid-render.
    private func wakeSelected() {
        if let selectedTab { runtime.wake(selectedTab) }
    }
}
