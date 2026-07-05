import ChromiumKit
import SwiftUI

struct AddressBar: View {
    let tab: TabRecord?
    @Environment(TabRuntime.self) private var runtime

    @FocusState private var fieldFocused: Bool
    @State private var editText: String = ""

    private var webView: ChromiumWebView? {
        tab.flatMap { runtime.liveWebView(for: $0) }
    }

    var body: some View {
        HStack(spacing: 8) {
            Button { webView?.goBack() } label: { Image(systemName: "chevron.left") }
                .disabled(webView?.observable.canGoBack != true)
                .help("Back")
            Button { webView?.goForward() } label: { Image(systemName: "chevron.right") }
                .disabled(webView?.observable.canGoForward != true)
                .help("Forward")
            if webView?.observable.isLoading == true {
                Button { webView?.stopLoading() } label: { Image(systemName: "xmark") }
                    .help("Stop")
            } else {
                Button { webView?.reload() } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(webView == nil)
                    .help("Reload")
            }

            centerArea
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
        .overlay(Divider(), alignment: .bottom)
    }

    /// TextField stays mounted so `@FocusState` has something to land on
    /// when the bar gets clicked; opacity + hit-testing swap which view is
    /// visible.
    private var centerArea: some View {
        ZStack {
            TextField("Search or enter URL", text: $editText)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .focused($fieldFocused)
                .onSubmit { navigate(to: editText) }
                .onExitCommand { fieldFocused = false }
                .opacity(fieldFocused ? 1 : 0)
                .allowsHitTesting(fieldFocused)
                .accessibilityIdentifier("addressBar.field")

            Button {
                editText = tab?.url.absoluteString ?? ""
                fieldFocused = true
            } label: {
                HStack(spacing: 6) {
                    FaviconView(image: tab?.displayFavicon)
                    Text(tab?.displayTitle ?? "")
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(tab == nil)
            .opacity(fieldFocused ? 0 : 1)
            .allowsHitTesting(!fieldFocused)
            .accessibilityIdentifier("addressBar.display")
        }
    }

    private func navigate(to raw: String) {
        guard let tab else { return }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let withScheme = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let url = URL(string: withScheme) else { return }
        // Wake-if-needed, then navigate. A freshly woken view loads the record's
        // URL; loading the typed URL right after just navigates it onward.
        runtime.wake(tab).load(url)
        fieldFocused = false
    }
}
