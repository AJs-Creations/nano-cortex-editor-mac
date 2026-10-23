// Cortex Cloud → the pedal for IRs, and the Cloud toolbar's audition controls (parity with the Electron edition's
// src/main.js, src/cloud-preload.js, src/cloud-ir.js and src/toolbar.html, from its PR #14).
//
// On the signed-in account's Impulse Responses page (`/cloud/profile/impulses`) a page script adds **Send to Nano** to
// each IR row. Its click posts {productId, name} to a script message handler; every message is checked (main frame,
// a Cortex Cloud origin over https, the web view on the IR page, a UUID product id) before the app downloads the WAV
// with the page's own session, checks it (≤ 1 MB, a sane `fmt ` chunk) and hands it to the store, which confirms with
// the user and sends it (type 15). The reply tells the button what happened (On Nano, Sent, Cancelled, Retry).
// If Neural DSP changes that page, the script quietly adds no buttons and the site works as before.

import SwiftUI
import WebKit
import NanoCore

@MainActor
final class CloudIRBridge: NSObject, WKScriptMessageHandlerWithReply {
    static let irPage = URL(string: "https://cloud.neuraldsp.com/cloud/profile/impulses")!
    static let handlerName = "nanoCloudIR"
    private(set) static var shared: CloudIRBridge?

    private let store: PedalStore
    private let cloud: CloudController
    private var observations: [NSKeyValueObservation] = []

    private init(store: PedalStore, cloud: CloudController) { self.store = store; self.cloud = cloud }

    /// Installs the page script and the message handler on the Cloud web view (once).
    static func install(store: PedalStore, cloud: CloudController) {
        guard shared == nil else { return }
        let bridge = CloudIRBridge(store: store, cloud: cloud)
        let content = cloud.webView.configuration.userContentController
        // The page world: the script reads the IR records React keeps on the list's DOM nodes.
        content.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .page))
        content.addScriptMessageHandler(bridge, contentWorld: .page, name: handlerName)
        // A document loaded before the install (the first page) or a single-page move to the IR list gets it here.
        bridge.observations = [
            cloud.webView.observe(\.url, options: [.new]) { [weak bridge] _, _ in Task { @MainActor in bridge?.injectIfIRPage() } },
            cloud.webView.observe(\.isLoading, options: [.new]) { [weak bridge] _, _ in Task { @MainActor in bridge?.injectIfIRPage() } },
        ]
        shared = bridge
        bridge.injectIfIRPage()
    }

    static func isIRPage(_ url: URL?) -> Bool { CloudController.isCloudHost(url) && IRTransfer.isIRPagePath(url?.path ?? "") }

    private func injectIfIRPage() {
        guard Self.isIRPage(cloud.webView.url), !cloud.webView.isLoading else { return }
        cloud.webView.evaluateJavaScript(Self.script, in: nil, in: .page) { _ in }   // idempotent per document
    }

    // MARK: messages from the page

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) async -> (Any?, String?) {
        let refused = { (why: String) -> (Any?, String?) in (CloudIROutcome(error: why).dictionary, nil) }
        let origin = message.frameInfo.securityOrigin
        guard message.webView === cloud.webView, message.frameInfo.isMainFrame, origin.protocol == "https",
              CloudController.isCloudHost(URL(string: "https://\(origin.host)")), Self.isIRPage(cloud.webView.url) else {
            return refused("Open your Cortex Cloud Impulse Responses page first.")
        }
        guard let body = message.body as? [String: Any], let id = body["productId"] as? String, IRTransfer.isProductId(id) else {
            return refused("This Cloud IR has an invalid product ID.")
        }
        let listed = String(((body["name"] as? String) ?? "").prefix(256))
        store.append("Cloud IR: Send to Nano for \"\(listed)\" (\(id))")
        let outcome: CloudIROutcome
        do { outcome = await store.receiveCloudIR(try await fetch(productId: id, listedName: listed)) }
        catch {
            let why = transferMessage(error)
            store.append("Cloud IR download failed: \(why)")
            store.toast("Could not fetch the IR: \(why)")
            outcome = CloudIROutcome(name: listed, error: why)
        }
        return (outcome.dictionary, nil)
    }

    /// `GET /api/v1/products/<id>/download` with the page's session (as the capture send does): `{id, name, payload}`,
    /// the payload base64 of the WAV. At most 1 MB decoded; the `fmt ` chunk checked.
    func fetch(productId id: String, listedName: String) async throws -> CloudIRBundle {
        guard IRTransfer.isProductId(id) else { throw IRError("This Cloud IR has an invalid product ID.") }
        guard CloudController.isCloudHost(cloud.webView.url) else { throw IRError("Open your Cortex Cloud Impulse Responses page first.") }
        let limit = (IRTransfer.maxBytes + 2) / 3 * 4 + 4
        let js = """
            let r;
            try { r = await fetch('https://cloud-api.neuraldsp.com/api/v1/products/' + id + '/download', { credentials: 'include' }); }
            catch (e) { return { error: 'Could not reach Cortex Cloud: ' + String(e && e.message || e) }; }
            if (!r.ok) return { error: 'Cortex Cloud answered ' + r.status + (r.status === 401 ? ' (sign in to Cortex Cloud first)' : '') };
            let j;
            try { j = await r.json(); } catch (e) { return { error: 'Cortex Cloud returned an unreadable IR download.' }; }
            if (!j) return { error: 'The Cloud response has no IR payload.' };
            const p = typeof j.payload === 'string' ? j.payload : '';
            return { id: String(j.id || ''), name: String(j.name || ''), length: p.length, payload: p.length > limit ? '' : p };
            """
        let result = try await cloud.webView.callAsyncJavaScript(js, arguments: ["id": id, "limit": limit], contentWorld: .defaultClient)
        guard let d = result as? [String: Any] else { throw IRError("Cortex Cloud returned an unreadable IR download.") }
        if let why = d["error"] as? String { throw IRError(why) }
        if let rid = d["id"] as? String, !rid.isEmpty, rid.lowercased() != id.lowercased() { throw IRError("Cortex Cloud returned a different product than the selected IR.") }
        if ((d["length"] as? NSNumber)?.intValue ?? 0) > limit { throw IRError("The IR is larger than 1 MB; the pedal takes short IR WAV files.") }
        let wav = try IRTransfer.decodePayload(d["payload"] as? String ?? "")
        _ = try WAVCheck.check(wav)
        return Self.bundle(wav: wav, productId: id, name: d["name"] as? String ?? "", listedName: listedName)
    }

    static func bundle(wav: [UInt8], productId: String, name: String, listedName: String) -> CloudIRBundle {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines), listed = listedName.trimmingCharacters(in: .whitespacesAndNewlines)
        let n = !trimmed.isEmpty ? trimmed : !listed.isEmpty ? listed : "Cloud impulse response"
        return CloudIRBundle(wav: wav, productId: productId, name: n, filename: IRTransfer.filename(for: n))
    }

    /// The page script (src/main.js `CLOUD_IR_ACTION_SCRIPT`, with the native message handler in place of the
    /// Electron preload). The account's IR list is a React app whose list component keeps the product records it got
    /// from the account-list API (productId, name); each row gets a button that posts its record.
    static let script = #"""
    (() => {
      if (window.__nanoCloudIRActions) return;
      const style = document.createElement('style');
      style.id = 'nano-cloud-ir-actions-style';
      style.textContent = '.nano-cloud-ir-row{position:relative!important;padding-right:126px!important}.nano-cloud-ir-send{position:absolute!important;right:8px!important;top:50%!important;transform:translateY(-50%)!important;z-index:5!important;padding:6px 10px!important;border:1px solid #7766ff!important;border-radius:6px!important;background:#6954ff!important;color:#fff!important;font:600 12px/1.2 system-ui,sans-serif!important;white-space:nowrap!important;cursor:pointer!important}.nano-cloud-ir-send:hover{filter:brightness(1.12)!important}.nano-cloud-ir-send:disabled{opacity:.62!important;cursor:wait!important}.nano-cloud-ir-send.nano-cloud-ir-on-nano:disabled{opacity:.9!important;cursor:default!important;background:#252333!important;border-color:#5d5683!important;color:#d5d0ff!important}';
      document.documentElement.appendChild(style);

      const idPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
      const send = (productId, name) => {
        const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.nanoCloudIR;
        if (!handler) return Promise.reject(new Error('The Nano Cortex Editor action is unavailable.'));
        return handler.postMessage({ productId: String(productId), name: String(name) });
      };
      function productEntries(row) {
        const fiberKey = Object.keys(row).find(key => key.startsWith('__reactFiber'));
        let fiber = fiberKey ? row[fiberKey] : null;
        for (let depth = 0; fiber && depth < 16; depth++, fiber = fiber.return) {
          const entries = fiber.memoizedProps && fiber.memoizedProps.entries;
          if (Array.isArray(entries) && entries.length && entries.every(item => item && item.productId && item.name)) return entries;
        }
        return null;
      }
      function itemName(row) {
        const input = row.querySelector('input[type="checkbox"]');
        return String(input && input.name || '').replace(/\s+checkbox$/i, '').trim();
      }
      function scan() {
        if (!/^\/cloud\/profile\/impulses\/?$/i.test(location.pathname)) return;
        const rows = [...document.querySelectorAll('main li input[type="checkbox"]')]
          .map(input => input.closest('li')).filter(Boolean);
        const lists = new Map();
        for (const row of rows) {
          if (!lists.has(row.parentElement)) lists.set(row.parentElement, []);
          lists.get(row.parentElement).push(row);
        }
        for (const [list, listRows] of lists) {
          const entries = productEntries(listRows[0]);
          if (!entries) continue;
          for (const row of listRows) {
            const name = itemName(row);
            if (!name) continue;
            const rowIndex = [...list.children].indexOf(row);
            let entry = entries[rowIndex];
            if (!entry || entry.name !== name) {
              const occurrence = listRows.slice(0, listRows.indexOf(row) + 1).filter(item => itemName(item) === name).length - 1;
              entry = entries.filter(item => item.name === name)[occurrence];
            }
            if (!entry || entry.name !== name || !idPattern.test(String(entry.productId))) continue;
            let button = row.querySelector(':scope > .nano-cloud-ir-send');
            if (button && button.dataset.productId === String(entry.productId)) continue;
            if (button) button.remove();
            row.classList.add('nano-cloud-ir-row');
            button = document.createElement('button');
            button.type = 'button';
            button.className = 'nano-cloud-ir-send';
            button.textContent = 'Send to Nano';
            button.title = 'Send ' + name + ' to the Nano Cortex IR library';
            button.setAttribute('aria-label', 'Send ' + name + ' to Nano Cortex');
            button.dataset.productId = String(entry.productId);
            button.addEventListener('click', async event => {
              event.preventDefault();
              event.stopPropagation();
              if (button.disabled) return;
              button.disabled = true;
              button.textContent = 'Sending…';
              button.title = 'Fetching and sending ' + name;
              try {
                const result = await send(entry.productId, name);
                if (result && result.alreadyOnNano) {
                  button.textContent = 'On Nano';
                  button.classList.add('nano-cloud-ir-on-nano');
                  button.title = (result.name || name) + ' is already in the Nano Cortex IR library.';
                  button.setAttribute('aria-label', (result.name || name) + ' is already on Nano Cortex');
                } else if (result && result.ok && result.refreshed) {
                  button.textContent = 'On Nano';
                  button.classList.add('nano-cloud-ir-on-nano');
                  button.title = (result.name || name) + ' is now in the Nano Cortex IR library.';
                  button.setAttribute('aria-label', (result.name || name) + ' is on Nano Cortex');
                } else if (result && result.ok) {
                  button.disabled = false;
                  button.textContent = 'Sent';
                  button.title = name + ' was sent; refresh the pedal library if it is not visible yet.';
                  setTimeout(() => { if (button.isConnected) { button.textContent = 'Send to Nano'; } }, 3000);
                } else if (result && result.cancelled) {
                  button.disabled = false;
                  button.textContent = 'Cancelled';
                  setTimeout(() => { if (button.isConnected) button.textContent = 'Send to Nano'; }, 1800);
                } else {
                  throw new Error(result && result.error || 'The IR was not sent.');
                }
              } catch (error) {
                button.disabled = false;
                button.textContent = 'Retry';
                button.title = error && error.message || 'The IR was not sent.';
              }
            });
            row.appendChild(button);
          }
        }
      }
      let scheduled = false;
      const scheduleScan = () => {
        if (scheduled) return;
        scheduled = true;
        requestAnimationFrame(() => { scheduled = false; scan(); });
      };
      const observer = new MutationObserver(scheduleScan);
      observer.observe(document.documentElement, { childList: true, subtree: true });
      window.__nanoCloudIRActions = { observer, scan };
      scan();
    })();
    """#
}

// MARK: Cloud toolbar controls (src/toolbar.html `#c-irs`, `#c-preview`, `#c-ir`)

/// **IRs**: your Cortex Cloud impulse responses, where each IR gets Send to Nano.
struct CloudIRsButton: View {
    @Environment(CloudController.self) private var cloud
    var body: some View {
        Button("IRs") { cloud.go(CloudIRBridge.irPage) }.buttonStyle(BarButton()).help("Open your Cortex Cloud impulse responses")
            .accessibilityIdentifier("cloud-irs")
    }
}

/// **Live Preview / Stop Preview**: plays the capture of this page on the pedal without storing it. "Preparing..." and
/// "Stopping..." while that happens; the state machine (`CapturePreviewState`) always ends in Live or Stop Preview.
struct LivePreviewButton: View {
    @Environment(PedalStore.self) private var store
    @Environment(CloudController.self) private var cloud
    var body: some View {
        let p = store.auditions.capture, onCapture = cloud.captureId != nil
        let enabled = p.buttonEnabled(onCapturePage: onCapture, connected: store.connected)
        Button(p.buttonTitle) { act() }
            .buttonStyle(BarButton(primary: true)).disabled(!enabled)
            .help(p.buttonHelp(onCapturePage: onCapture, connected: store.connected))
            .accessibilityIdentifier("cloud-preview")
    }
    private func act() {
        cloud.message = nil
        if store.auditions.capture.phase == .active {
            Task { if !(await store.stopCapturePreview()) { let e = store.auditions.capture.error; if !e.isEmpty { cloud.message = e } } }
        } else if let id = cloud.captureId {
            Task { if let why = await store.startCapturePreview(fetch: { try await cloud.fetchBundle(id: id) }) { cloud.message = why } }
        }
    }
}

/// **IR: On / Off**: the current preset's cab, to hear a previewed capture with or without it.
struct CabIRToggle: View {
    @Environment(PedalStore.self) private var store
    @Environment(CloudController.self) private var cloud
    var body: some View {
        let on = store.connected && store.cab.on
        Button("IR: " + (on ? "On" : "Off")) { if let why = store.toggleCabIR() { cloud.message = why } }
            .buttonStyle(BarButton(primary: true))
            .disabled(!store.connected || store.auditions.capture.busy)
            .help(!store.connected ? "Toggle Cab / IR processing on the Nano" : on ? "Bypass Cab / IR processing on the Nano" : "Enable Cab / IR processing on the Nano")
            .accessibilityIdentifier("cloud-ir-toggle")
    }
}
