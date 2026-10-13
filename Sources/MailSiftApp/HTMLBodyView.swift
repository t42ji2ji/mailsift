import SwiftUI
import WebKit

/// Renders a message's HTML with JavaScript off and every http/https load blocked (no tracking pixels, no remote
/// images). Links open nothing.
struct HTMLBodyView: NSViewRepresentable {
    let html: String

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        guard context.coordinator.loaded != html else { return }
        context.coordinator.loaded = html
        let html = html
        Task { @MainActor in
            if let rules = await Self.blockRemote() {
                view.configuration.userContentController.removeAllContentRuleLists()
                view.configuration.userContentController.add(rules)
                view.loadHTMLString(html, baseURL: nil)
            } else {
                view.loadHTMLString("", baseURL: nil)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        var loaded: String?

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            action.navigationType == .other ? .allow : .cancel
        }
    }

    private static let rulesJSON = #"[{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}}]"#

    @MainActor private static var cached: WKContentRuleList?

    @MainActor private static func blockRemote() async -> WKContentRuleList? {
        if let cached { return cached }
        let list = try? await WKContentRuleListStore.default()
            .compileContentRuleList(forIdentifier: "mailsift-block-remote", encodedContentRuleList: rulesJSON)
        cached = list
        return list
    }
}
