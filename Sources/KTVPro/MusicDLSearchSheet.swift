import AppKit
import SwiftUI
import WebKit

@MainActor
private final class MusicDLBrowser: NSObject, ObservableObject, WKNavigationDelegate {
    @Published private(set) var pageError: String?
    @Published private(set) var status = "试听确认后可点「加入曲库」。已下载的音频会直接复用。"
    @Published private(set) var adding = false

    private let importer: MusicDLImporter
    private let onAdded: (LibrarySong) -> Void
    private var addTask: Task<Void, Never>?

    init(importer: MusicDLImporter, onAdded: @escaping (LibrarySong) -> Void) {
        self.importer = importer
        self.onAdded = onAdded
    }

    lazy var webView: WKWebView = {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let content = configuration.userContentController
        content.add(MessageBridge(browser: self), contentWorld: .defaultClient, name: "ktakeImport")
        content.addUserScript(WKUserScript(source: Self.addImportButtons, injectionTime: .atDocumentEnd,
                                           forMainFrameOnly: true, in: .defaultClient))
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        return view
    }()

    func load() {
        pageError = nil
        webView.load(URLRequest(url: MusicDLImporter.baseURL.appendingPathComponent("", isDirectory: true), timeoutInterval: 30))
    }

    func close() {
        addTask?.cancel()
        webView.stopLoading()
        webView.loadHTMLString("", baseURL: nil)
    }

    func cancelAdd() { addTask?.cancel() }

    private func importTrack(_ track: MusicDLTrack) {
        guard !adding else { return }
        adding = true
        status = "正在将「\(track.title)」加入曲库并匹配同步歌词…"
        addTask = Task {
            defer {
                adding = false
                addTask = nil
            }
            do {
                let song = try await importer.add(track)
                let result = song.lyrics == nil ? "未找到匹配的同步歌词" : "已匹配同步歌词"
                status = "已加入曲库：\(song.displayName) · \(result)"
                onAdded(song)
            } catch {
                status = Task.isCancelled ? "已取消加入曲库。" : "加入曲库失败：\(error.localizedDescription)"
            }
        }
    }

    private static func isServicePage(_ url: URL) -> Bool {
        let service = MusicDLImporter.baseURL
        return url.scheme == service.scheme && url.host == service.host && url.port == service.port &&
            (url.path == service.path || url.path.hasPrefix(service.path + "/"))
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { decisionHandler(.cancel); return }
        if url.scheme == "about" || action.targetFrame?.isMainFrame == false {
            decisionHandler(.allow)
        } else if Self.isServicePage(url) {
            if action.targetFrame == nil {
                decisionHandler(.cancel)
                if action.navigationType == .linkActivated { webView.load(action.request) }
            } else { decisionHandler(.allow) }
        } else {
            decisionHandler(.cancel)
            if action.navigationType == .linkActivated, ["http", "https"].contains(url.scheme ?? "") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled {
            pageError = "无法打开本机 music-dl。请确认 OrbStack 中的 go-music-dl 已启动，然后点「重新加载」。"
        }
    }

    private final class MessageBridge: NSObject, WKScriptMessageHandler {
        weak var browser: MusicDLBrowser?
        init(browser: MusicDLBrowser) { self.browser = browser }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, let page = message.frameInfo.request.url,
                  MusicDLBrowser.isServicePage(page), let fields = message.body as? [String: String],
                  let track = MusicDLTrack(fields: fields) else { return }
            browser?.importTrack(track)
        }
    }

    // The upstream search endpoint renders its public song-card template.
    // Add one KTake action while leaving filtering and playback to the page.
    private static let addImportButtons = """
    (() => {
        const addButtons = () => {
            for (const card of document.querySelectorAll('.song-card[data-id][data-source]')) {
                const actions = card.querySelector('.actions');
                if (!actions || actions.querySelector('[data-ktake-import]')) continue;
                const button = document.createElement('button');
                button.type = 'button';
                button.setAttribute('data-ktake-import', '');
                button.textContent = '加入曲库';
                button.style.cssText = 'border:1px solid #a48af0;border-radius:7px;padding:6px 9px;background:transparent;color:inherit;font:inherit;font-size:12px;cursor:pointer;white-space:nowrap;';
                button.addEventListener('click', (event) => {
                    if (!event.isTrusted) return;
                    event.preventDefault();
                    event.stopPropagation();
                    const { id, source, name, artist, album, duration, extra } = card.dataset;
                    window.webkit.messageHandlers.ktakeImport.postMessage({
                        id, source, title: name || '', artist: artist || '', album: album || '',
                        duration: duration || '', extra: extra || '',
                        link: card.querySelector('a.song-title-link')?.href || ''
                    });
                });
                const play = actions.querySelector('.btn-play');
                if (play) play.after(button);
                else actions.prepend(button);
            }
        };
        addButtons();
        new MutationObserver(addButtons).observe(document.body, {childList:true, subtree:true});
    })();
    """
}

struct MusicDLSearchSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var browser: MusicDLBrowser

    init(importer: MusicDLImporter = MusicDLImporter(), onAdded: @escaping (LibrarySong) -> Void) {
        _browser = StateObject(wrappedValue: MusicDLBrowser(importer: importer, onAdded: onAdded))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("music-dl 聚合搜索").font(.headline)
                Spacer()
                Button("重新加载") { browser.load() }
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(14)
            Divider()
            ZStack {
                MusicDLWebView(webView: browser.webView)
                if let error = browser.pageError {
                    Text(error).font(.callout).padding(18).background(StudioTheme.chrome, in: RoundedRectangle(cornerRadius: 10))
                }
            }
            Divider()
            HStack(spacing: 8) {
                if browser.adding { ProgressView().controlSize(.small) }
                Text(browser.status).textSelection(.enabled)
                Spacer()
                if browser.adding { Button("取消加入") { browser.cancelAdd() } }
            }.font(.callout).foregroundStyle(.secondary).padding(14)
        }
        .frame(minWidth: 880, idealWidth: 1020, minHeight: 550, idealHeight: 690)
        .studioSheet()
        .onAppear { browser.load() }
        .onDisappear { browser.close() }
    }
}

private struct MusicDLWebView: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ view: WKWebView, context: Context) {}
}
