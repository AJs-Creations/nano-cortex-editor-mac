// The Cortex Cloud tab: their real site in a WKWebView with a persistent session,
// controls in the window tab bar (back, forward, reload, home, Send to Nano, sign out), and
// the capture download → upload bridge. The web view never sees the pedal; the
// bundle is fetched with the page's own session and handed to the store.

import SwiftUI
import WebKit
import NanoCore

@MainActor @Observable
final class CloudController: NSObject {
    static let home = URL(string: "https://cloud.neuraldsp.com/cloud/")!
    static let capturePage = try! NSRegularExpression(pattern: "/neural-capture/view/([0-9a-f-]{36})", options: .caseInsensitive)

    let webView: WKWebView
    var url: URL?
    var title = ""
    var canGoBack = false
    var canGoForward = false
    var loading = false
    var captureId: String?
    var busy: String?          // "Fetching…"
    var message: String?       // last error, shown under the toolbar

    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()          // persistent cookies: the Cortex Cloud login survives relaunches
        config.applicationNameForUserAgent = "NanoCortexEditor"
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.load(URLRequest(url: Self.home))
        // The site is a single-page app: moving to a capture page changes the URL without a navigation callback,
        // so follow the web view's own properties instead of only the delegate events.
        let changed: (WKWebView, Any) -> Void = { [weak self] _, _ in Task { @MainActor in self?.sync() } }
        observers = [
            webView.observe(\.url, options: [.new], changeHandler: changed),
            webView.observe(\.title, options: [.new], changeHandler: changed),
            webView.observe(\.canGoBack, options: [.new], changeHandler: changed),
            webView.observe(\.canGoForward, options: [.new], changeHandler: changed),
            webView.observe(\.isLoading, options: [.new], changeHandler: changed),
        ]
    }
    private var observers: [NSKeyValueObservation] = []

    static func isCloudHost(_ url: URL?) -> Bool {
        guard let url, url.scheme == "https", let h = url.host?.lowercased() else { return false }
        return h == "neuraldsp.com" || h.hasSuffix(".neuraldsp.com")
    }
    static func captureId(of url: URL?) -> String? {
        guard let s = url?.absoluteString, let m = capturePage.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), let r = Range(m.range(at: 1), in: s) else { return nil }
        return String(s[r])
    }
    private func sync() {
        url = webView.url; title = webView.title ?? ""; canGoBack = webView.canGoBack; canGoForward = webView.canGoForward; loading = webView.isLoading
        captureId = Self.captureId(of: webView.url)
    }
    func go(_ url: URL) { webView.load(URLRequest(url: url)) }
    func back() { webView.goBack() }
    func forward() { webView.goForward() }
    func reload() { webView.reload() }
    func home() { go(Self.home) }

    func signOut() async {
        let store = WKWebsiteDataStore.default()
        let records = await store.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: records)
        home()
    }

    /// The client headers Cortex Cloud's own web client sends. Since late October 2026 the download API refuses a request
    /// without them ("400 4LV001 Incorrect header value"), before it even checks the session. JS object literal.
    static let apiClientHeadersJS = "{ 'X-Cloud-Api-Client-Type': 'web-cloud', 'X-Cloud-Api-Client-Version': '1.0.0' }"

    /// Fetches the capture bundle with the page's own session (same as the site's JS does), unpacked here.
    func fetchBundle(id: String) async throws -> CaptureBundle {
        guard Self.isCloudHost(webView.url) else { throw CloudError.message("Open Cortex Cloud first.") }
        let js = """
            const r = await fetch('https://cloud-api.neuraldsp.com/api/v1/products/' + id + '/download', { credentials: 'include', headers: \(Self.apiClientHeadersJS) });
            if (!r.ok) throw new Error('Cortex Cloud answered ' + r.status + (r.status === 401 ? ' (not signed in?)' : ''));
            const j = await r.json();
            return { payload: j.payload || '', name: j.name || '' };
            """
        let result = try await webView.callAsyncJavaScript(js, arguments: ["id": id], contentWorld: .defaultClient)
        guard let dict = result as? [String: Any], let payload = dict["payload"] as? String, !payload.isEmpty else { throw CloudError.message("The reply has no capture payload.") }
        return try CaptureBundle.parse(payloadBase64: payload, name: dict["name"] as? String, cloudId: id)
    }


    func snapshot() async -> NSImage? {
        try? await webView.takeSnapshot(configuration: nil)
    }
}

extension CaptureBundle: @retroactive Identifiable { public var id: String { record.hash } }

enum CloudError: Error, LocalizedError { case message(String); var errorDescription: String? { if case .message(let m) = self { m } else { nil } } }

extension CloudController: WKNavigationDelegate, WKUIDelegate {
    nonisolated func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        let url = action.request.url
        let mainFrame = action.targetFrame?.isMainFrame ?? true
        Task { @MainActor in
            // Only top-level navigations leave for the browser; embedded frames (cookie consent, players) stay.
            if !mainFrame || Self.isCloudHost(url) || url?.scheme == "about" { decisionHandler(.allow) }
            else { if let url { NSWorkspace.shared.open(url) }; decisionHandler(.cancel) }
        }
    }
    nonisolated func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { Task { @MainActor in sync() } }
    nonisolated func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { Task { @MainActor in sync() } }
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in sync() }
    }
    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { Task { @MainActor in sync(); message = error.localizedDescription } }
    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { Task { @MainActor in sync(); if (error as NSError).code != NSURLErrorCancelled { message = error.localizedDescription } } }
    // window.open: keep Cloud pages in this view, send everything else to the browser.
    nonisolated func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let url = action.request.url
        Task { @MainActor in if Self.isCloudHost(url), let url { go(url) } else if let url { NSWorkspace.shared.open(url) } }
        return nil
    }
}

struct CloudWebView: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ view: WKWebView, context: Context) {}
}

/// The Cloud tab's controls, shown in the window's tab bar (row 1) as in Electron's toolbar:
/// ← → ↻ Home, IRs, Send to Nano, Live Preview, IR: On/Off (CloudIR.swift), and a ⋯ menu. "Sign out" sits at the far right of the bar.
struct CloudToolbar: View {
    @Environment(PedalStore.self) private var store
    @Environment(CloudController.self) private var cloud
    var body: some View {
        HStack(spacing: 2) {
            Button("←") { cloud.back() }.buttonStyle(BarButton()).disabled(!cloud.canGoBack).help("Back")
            Button("→") { cloud.forward() }.buttonStyle(BarButton()).disabled(!cloud.canGoForward).help("Forward")
            Button("↻") { cloud.reload() }.buttonStyle(BarButton()).help("Reload")
            Button("Home") { cloud.home() }.buttonStyle(BarButton()).help("Cortex Cloud home")
            CloudIRsButton()
            let previewing = store.auditions.capture.phase != .idle   // Electron: no Send while a preview plays or changes
            Button(cloud.busy == "Fetching…" ? "Fetching…" : "Send to Nano Cortex") { Task { await send() } }.buttonStyle(BarButton(primary: cloud.captureId != nil && store.connected && cloud.busy == nil && !previewing))
                .disabled(cloud.captureId == nil || !store.connected || cloud.busy != nil || previewing)
                .help(sendHelp)
            LivePreviewButton()
            CabIRToggle()
            Menu {
                Button("Sign out of Cortex Cloud…") { store.confirmSignOut = true }
            } label: { Text("⋯") }
                .menuStyle(.button).menuIndicator(.hidden).buttonStyle(BarButton()).fixedSize()
            if cloud.loading { ProgressView().controlSize(.mini).padding(.leading, 6) }
        }
    }
    private var sendHelp: String {
        if cloud.captureId == nil { return "Open a capture page in Cortex Cloud first (presets are Quad Cortex only)." }
        if !store.connected { return "Connect your Nano Cortex first." }
        return "Send this capture to the pedal over Bluetooth. It lands in the library; presets don't change until you load it into a slot."
    }
    private func send() async {
        guard let id = cloud.captureId else { return }
        cloud.busy = "Fetching…"; cloud.message = nil
        do { let b = try await cloud.fetchBundle(id: id); store.offerSend(b) }
        catch { cloud.message = "Could not fetch the capture: \(error.localizedDescription)" }
        cloud.busy = nil
    }
}

/// The site itself, with errors above it (the controls live in the tab bar).
struct CloudTab: View {
    @Environment(CloudController.self) private var cloud
    var body: some View {
        VStack(spacing: 0) {
            if let m = cloud.message {
                HStack { Text(m).font(Theme.font(12)).foregroundStyle(Theme.danger); Spacer(); Button { cloud.message = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(Theme.faint) }
                    .padding(.horizontal, 12).frame(height: 28).background(Theme.raised)
                Rectangle().fill(Theme.line).frame(height: 1)
            }
            CloudWebView(webView: cloud.webView)
        }
    }
}

/// "Send X to the pedal?" — then the streamed upload with progress in the status bar.
struct SendSheet: View {
    @Environment(PedalStore.self) private var store
    let bundle: CaptureBundle
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ModalTitle("Send \(bundle.record.name) to the pedal?").padding(.bottom, 8)
            ModalText((bundle.record.authorName.isEmpty ? "" : "By \(bundle.record.authorName). ") + String(format: "%.1f KB over Bluetooth. It lands in the pedal’s library; nothing in your presets changes until you load it into a slot.", bundle.sizeKB)).padding(.bottom, 18)
            HStack(spacing: 8) { Spacer()
                Button("Cancel") { store.pendingSend = nil }.buttonStyle(ThemedButton()).keyboardShortcut(.cancelAction)
                Button("Send") { store.sendPending() }.buttonStyle(ThemedButton(kind: .primary)).keyboardShortcut(.defaultAction)
            }
        }.modalPanel(width: 440)
    }
}

/// After a successful upload: "Load X into a slot now?"
struct OfferSlotSheet: View {
    @Environment(PedalStore.self) private var store
    let offer: PedalStore.SlotChoice
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ModalTitle("Load \(offer.name) into a slot now?").padding(.bottom, 8)
            ModalText("You can also do it later from “Load from library…” in the Capture inspector.").padding(.bottom, 18)
            HStack(spacing: 8) { Spacer()
                Button("Later") { store.offerSlot = nil }.buttonStyle(ThemedButton()).keyboardShortcut(.cancelAction)
                Button("Choose a slot") { store.offerSlot = nil; store.slotChooser = offer }.buttonStyle(ThemedButton(kind: .primary)).keyboardShortcut(.defaultAction)
            }
        }.modalPanel()
    }
}
