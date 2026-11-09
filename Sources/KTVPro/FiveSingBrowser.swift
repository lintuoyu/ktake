import SwiftUI
import WebKit
import AppKit
import UniformTypeIdentifiers

private actor DownloadLibraryWriter {
    let root: URL
    let lyricClient: LyricSearchClient
    init(root: URL, lyricClient: LyricSearchClient) { self.root = root; self.lyricClient = lyricClient }
    func add(file: URL, title: String, artist: String, source: URL?, pageLyrics: String?) async throws -> (LibrarySong, String) {
        let identity = await LyricMatcher.audioIdentity(file: file, title: title, artist: artist)
        let song = try LibraryImporter.add(file: file, title: identity.0, artist: identity.1, sourceURL: source, root: root)
        let seconds = song.duration ?? 0
        do {
            let attachment: LyricAttachment?
            if let pageLyrics, LyricMatcher.usable(pageLyrics, duration: seconds) {
                attachment = LyricAttachment(lrc: pageLyrics, sourceURL: source?.absoluteString ?? "5sing")
            } else {
                attachment = try await lyricClient.find(title: song.title, artist: song.artist, duration: seconds)
            }
            let notice = attachment != nil ? "同步歌词已匹配" : "未找到曲名、歌手和时长匹配的同步歌词，可手动导入 LRC"
            let updated = try LibraryImporter.saveLyrics(songID: song.id, attachment: attachment, status: notice, root: root)
            return (updated, notice)
        } catch {
            let notice = "歌词匹配暂未完成：\(error.localizedDescription)；伴奏已保存"
            let updated = (try? LibraryImporter.saveLyrics(songID: song.id, attachment: nil, status: notice, root: root)) ?? song
            return (updated, notice)
        }
    }
}

@MainActor
final class FiveSingBrowser: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    @Published var keyword = "refrain"
    @Published var songName = ""
    @Published var artist = ""
    @Published var status = "在 5sing 登录，筛选「伴奏」，再点击歌曲的下载按钮。"
    @Published var loading = false
    @Published var currentAddress = ""
    @Published var canGoBack = false
    @Published var importing = false
    private var window: NSWindow?
    private var observations: [NSKeyValueObservation] = []
    private let writer: DownloadLibraryWriter
    private var downloads: [ObjectIdentifier: DownloadContext] = [:]
    private var metadata: FiveSingMetadata?
    var onAdded: ((LibrarySong) -> Void)?
    init(libraryRoot: URL = SongLibrary.userRoot, lyricClient: LyricSearchClient = .shared) {
        writer = DownloadLibraryWriter(root: libraryRoot, lyricClient: lyricClient)
        super.init()
    }
    private struct DownloadContext {
        let folder: URL
        var file: URL?
        let source: URL?
        let title: String
        let artist: String
        let pageLyrics: String?
    }
    lazy var webView: WKWebView = {
        let configuration = WKWebViewConfiguration()
        // WebKit owns persistent login cookies. The app never reads credentials.
        configuration.websiteDataStore = .default()
        configuration.userContentController.add(FiveSingMessageBridge(owner: self), name: "songMetadata")
        configuration.userContentController.addUserScript(WKUserScript(source: FiveSingMetadata.script, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        view.uiDelegate = self
        view.allowsBackForwardNavigationGestures = true
        observations = [
            view.observe(\.isLoading, options: [.new]) { [weak self] view, _ in
                Task { @MainActor in self?.loading = view.isLoading }
            },
            view.observe(\.url, options: [.new]) { [weak self] view, _ in
                Task { @MainActor in self?.currentAddress = view.url?.absoluteString ?? ""; self?.canGoBack = view.canGoBack }
            }
        ]
        return view
    }()

    func show() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1160, height: 820),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "5sing 伴奏曲库"
            window.minSize = NSSize(width: 960, height: 680)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: FiveSingView(browser: self))
            window.center()
            self.window = window
            search()
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func searchURL(_ keyword: String) -> URL {
        var url = URLComponents(string: "http://search.5sing.kugou.com/")!
        url.queryItems = [URLQueryItem(name: "keyword", value: keyword.trimmingCharacters(in: .whitespacesAndNewlines))]
        return url.url!
    }

    func search() {
        guard !keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        webView.load(URLRequest(url: Self.searchURL(keyword)))
    }

    func receiveMetadata(_ value: FiveSingMetadata) {
        let changed = metadata?.pageURL.path != value.pageURL.path
        if changed || songName.isEmpty { songName = value.title }
        if changed || artist.isEmpty { artist = value.artist }
        metadata = value
    }

    private func pageLyricsForCurrentSong() -> String? {
        guard let metadata, LyricMatcher.normalized(metadata.title) == LyricMatcher.normalized(songName),
              artist.isEmpty || metadata.artist.isEmpty || LyricMatcher.normalized(metadata.artist) == LyricMatcher.normalized(artist) else { return nil }
        return metadata.lrc
    }

    func openExternally() {
        if let url = webView.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            NSWorkspace.shared.open(url)
        }
    }

    func importDownloadedFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.message = "选择从 5sing 下载的伴奏，将复制到 KTake 曲库"
        guard let window else { return }
        panel.beginSheetModal(for: window) { [weak self] result in
            guard result == .OK, let file = panel.url else { return }
            Task { @MainActor in
                guard let self else { return }
                self.addToLibrary(file, title: self.songName, artist: self.artist, source: self.metadata?.pageURL ?? self.webView.url, pageLyrics: self.pageLyricsForCurrentSong())
            }
        }
    }

    private func addToLibrary(_ file: URL, title: String, artist: String, source: URL?, pageLyrics: String?, cleanup: URL? = nil) {
        importing = true
        status = "正在校验音频、自动命名并匹配同步歌词…"
        Task {
            defer {
                if let cleanup { try? FileManager.default.removeItem(at: cleanup) }
                importing = false
            }
            do {
                let (song, notice) = try await writer.add(file: file, title: title, artist: artist, source: source, pageLyrics: pageLyrics)
                status = "已加入：\(song.displayName) · \(notice)"
                onAdded?(song)
            } catch { status = "加入失败：\(error.localizedDescription)；请确认下载的是音频文件。" }
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        let scheme = url.scheme?.lowercased() ?? ""
        guard ["http", "https", "about", "blob", "data"].contains(scheme) else {
            status = "此链接需要外部应用；可使用「外部浏览器」继续。"
            decisionHandler(.cancel)
            return
        }
        let audioExtensions = ["mp3", "m4a", "wav", "aiff", "aif", "flac", "aac", "ogg", "wma"]
        if navigationAction.shouldPerformDownload ||
            (navigationAction.navigationType == .linkActivated && audioExtensions.contains(url.pathExtension.lowercased())) {
            decisionHandler(.download)
        } else { decisionHandler(.allow) }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        let mime = navigationResponse.response.mimeType?.lowercased() ?? ""
        let disposition = (navigationResponse.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition") ?? ""
        if navigationResponse.isForMainFrame && (mime.hasPrefix("audio/") || disposition.lowercased().contains("attachment") || !navigationResponse.canShowMIMEType) {
            decisionHandler(.download)
        } else { decisionHandler(.allow) }
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        begin(download, source: webView.url)
    }
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        begin(download, source: webView.url)
    }
    private func begin(_ download: WKDownload, source: URL?) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ktvpro-download-\(UUID().uuidString)")
        let pageLyrics = pageLyricsForCurrentSong()
        downloads[ObjectIdentifier(download)] = DownloadContext(folder: folder, source: metadata?.pageURL ?? source, title: songName, artist: artist, pageLyrics: pageLyrics)
        download.delegate = self
        status = "正在下载伴奏…"
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String,
                  completionHandler: @escaping (URL?) -> Void) {
        let id = ObjectIdentifier(download)
        guard var context = downloads[id] else { completionHandler(nil); return }
        do {
            try FileManager.default.createDirectory(at: context.folder, withIntermediateDirectories: true)
            let name = (suggestedFilename as NSString).lastPathComponent
            let file = context.folder.appendingPathComponent(name.isEmpty || name == "." || name == ".." ? "accompaniment.audio" : name)
            context.file = file
            downloads[id] = context
            completionHandler(file)
        } catch { status = "无法保存下载：\(error.localizedDescription)"; completionHandler(nil) }
    }
    func downloadDidFinish(_ download: WKDownload) {
        guard let context = downloads.removeValue(forKey: ObjectIdentifier(download)), let file = context.file else { return }
        addToLibrary(file, title: context.title, artist: context.artist, source: context.source, pageLyrics: context.pageLyrics, cleanup: context.folder)
    }
    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        if let context = downloads.removeValue(forKey: ObjectIdentifier(download)) { try? FileManager.default.removeItem(at: context.folder) }
        status = "下载失败：\(error.localizedDescription)。可在外部浏览器下载后导入。"
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
        return nil
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        canGoBack = webView.canGoBack
        webView.evaluateJavaScript(FiveSingMetadata.script, completionHandler: nil)
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { status = "网页加载失败：\(error.localizedDescription)。可点击重新加载或使用外部浏览器。" }
    }
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        guard let window else { completionHandler(); return }
        let alert = NSAlert(); alert.messageText = "5sing 网页提示"; alert.informativeText = message
        alert.beginSheetModal(for: window) { _ in completionHandler() }
    }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        guard let window else { completionHandler(false); return }
        let alert = NSAlert(); alert.messageText = "5sing 网页确认"; alert.informativeText = message
        alert.addButton(withTitle: "确定"); alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { completionHandler($0 == .alertFirstButtonReturn) }
    }
}

private struct FiveSingWebView: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ view: WKWebView, context: Context) { }
}

private struct FiveSingView: View {
    @ObservedObject var browser: FiveSingBrowser
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("5sing").font(.system(size: 20, weight: .semibold, design: .rounded))
                TextField("歌曲名 / 歌手", text: $browser.keyword).textFieldStyle(.roundedBorder)
                    .onSubmit { browser.search() }
                Button("搜索") { browser.search() }.keyboardShortcut(.return, modifiers: .command)
                Button { browser.webView.goBack() } label: { Image(systemName: "chevron.left") }.disabled(!browser.canGoBack).help("后退")
                Button { browser.webView.reload() } label: { Image(systemName: "arrow.clockwise") }.help("重新加载")
                Button("外部浏览器") { browser.openExternally() }
            }.padding(16)
            HStack {
                if browser.loading { ProgressView().controlSize(.small) }
                Text(browser.currentAddress).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Text("使用网页登录与验证").font(.system(size: 11)).foregroundStyle(.secondary)
            }.padding(.horizontal, 16).padding(.bottom, 10)
            Divider()
            FiveSingWebView(webView: browser.webView)
            Divider()
            HStack(spacing: 12) {
                Text("下载入库").font(.system(size: 12, weight: .medium))
                TextField("曲名（从网页自动识别，可修改）", text: $browser.songName).textFieldStyle(.roundedBorder)
                TextField("原唱（自动识别）", text: $browser.artist).textFieldStyle(.roundedBorder).frame(width: 170)
                Button("导入已下载文件") { browser.importDownloadedFile() }.disabled(browser.importing)
            }.padding(.horizontal, 16).padding(.top, 12)
            Text("自动保存为「歌手 - 曲名 (伴奏)」，并按曲名、歌手和时长匹配同步歌词。")
                .font(.system(size: 10)).foregroundStyle(.tertiary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.top, 6)
            HStack {
                if browser.importing { ProgressView().controlSize(.small) }
                Text(browser.status).font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
                Spacer()
            }.padding(16)
        }
        .frame(minWidth: 960, minHeight: 680)
        .background(StudioTheme.chrome)
        .tint(StudioTheme.accent)
        .preferredColorScheme(.dark)
    }
}
