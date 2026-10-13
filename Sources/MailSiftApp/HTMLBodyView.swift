import AppKit
import SwiftUI
import WebKit

/// Renders a message's HTML with JavaScript off. Remote loads (tracking pixels, images) are blocked unless
/// `allowRemote`; links open in the default browser.
struct HTMLBodyView: NSViewRepresentable {
    let html: String
    var allowRemote = false

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")  // let the pane color show through transparent mail
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        let key = "\(allowRemote)|\(html.hashValue)"
        guard context.coordinator.loaded != key else { return }
        context.coordinator.loaded = key
        let page = Self.wrap(html)
        let allowRemote = allowRemote
        Task { @MainActor in
            let controller = view.configuration.userContentController
            controller.removeAllContentRuleLists()
            if !allowRemote {
                guard let rules = await Self.blockRemote() else {
                    view.loadHTMLString("", baseURL: nil)
                    return
                }
                controller.add(rules)
            }
            view.loadHTMLString(page, baseURL: nil)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        var loaded: String?

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            if action.navigationType == .linkActivated, let url = action.request.url,
               ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                NSWorkspace.shared.open(url)
                return .cancel
            }
            return action.navigationType == .other ? .allow : .cancel
        }
    }

    /// Mail HTML is written for a fixed-width white canvas; keep it readable in a resizable pane.
    private static let style = """
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
        html { background: transparent; }
        body { margin: 0; padding: 4px 36px 40px; font: 14px/1.6 -apple-system, "PingFang TC", sans-serif;
               color: #1d1d1f; word-wrap: break-word; overflow-wrap: anywhere; -webkit-text-size-adjust: none; }
        img { max-width: 100% !important; height: auto !important; }
        table { max-width: 100% !important; }
        pre { white-space: pre-wrap; }
        a { color: inherit; text-decoration: underline; text-underline-offset: 2px; }
        blockquote { margin-left: 0; padding-left: 12px; border-left: 2px solid rgba(0,0,0,.15); color: #555; }
        </style>
        """

    static func wrap(_ html: String) -> String {
        if let head = html.range(of: "<head[^>]*>", options: [.regularExpression, .caseInsensitive]) {
            var out = html
            out.insert(contentsOf: style, at: head.upperBound)
            return out
        }
        return "<!doctype html><html><head>\(style)</head><body>\(html)</body></html>"
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

enum Linkify {
    private static let detector = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// Plain text with URLs and e-mail addresses as clickable links.
    static func attributed(_ text: String) -> AttributedString {
        var out = AttributedString(text)
        let ns = text as NSString
        for match in detector.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard let url = match.url, let range = Range(match.range, in: text),
                  let lower = AttributedString.Index(range.lowerBound, within: out),
                  let upper = AttributedString.Index(range.upperBound, within: out) else { continue }
            out[lower..<upper].link = url
            out[lower..<upper].underlineStyle = .single
        }
        return out
    }
}
