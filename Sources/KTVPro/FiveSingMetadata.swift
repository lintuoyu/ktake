import Foundation
import WebKit

struct FiveSingMetadata {
    let title: String
    let artist: String
    let pageURL: URL
    let lrc: String?

    // Read only public song fields. No account, cookie or authentication data is accessed.
    static let script = #"""
    (() => {
      if (!(location.hostname === '5sing.kugou.com' || location.hostname === 'search.5sing.kugou.com')) return;
      const clean = value => (value || '').trim().slice(0, 200);
      const send = value => window.webkit.messageHandlers.songMetadata.postMessage(value);
      function detail() {
        const match = location.pathname.match(/^\/(bz|fc|yc)\/(\d+)\.html$/);
        const title = clean(document.querySelector('.view_tit h1')?.textContent);
        if (!match || !title) return;
        const original = [...document.querySelectorAll('li')].find(li => /^原唱[：:]$/.test(clean(li.querySelector('em')?.textContent)));
        const artist = clean(original?.querySelector('a')?.textContent);
        const lrc = [...document.querySelectorAll('.lrc_info_clip')].map(e => e.innerText).find(t => /\[\d+:[0-5]?\d/.test(t)) || '';
        send({title, artist, pageURL: location.origin + location.pathname, lrc: lrc.slice(0, 100000)});
      }
      if (window.__ktvSongMetadataInstalled) { detail(); return; }
      window.__ktvSongMetadataInstalled = true;
      document.addEventListener('click', event => {
        const link = event.target.closest?.('a');
        if (!link) return;
        const url = new URL(link.href, location.href);
        const match = url.pathname.match(/^\/(bz|fc|yc)\/(?:down\/)?(\d+)(?:\.html)?$/);
        if (!match || url.hostname !== '5sing.kugou.com') { detail(); return; }
        if (location.hostname !== 'search.5sing.kugou.com') { detail(); return; }
        const path = '/' + match[1] + '/' + match[2] + '.html';
        const songLink = [...document.querySelectorAll('li.c2 a')].find(a => new URL(a.href, location.href).pathname === path);
        if (!songLink) return;
        const titleCell = songLink.closest('li');
        const header = [...document.querySelectorAll('ul.header li')].find(e => clean(e.textContent) === '原唱');
        const artistClass = header && [...header.classList].find(c => /^c\d+$/.test(c));
        let artist = '';
        for (let cell = titleCell.nextElementSibling; cell && !cell.classList.contains('c1'); cell = cell.nextElementSibling) {
          if (artistClass && cell.classList.contains(artistClass)) { artist = clean(cell.textContent); break; }
        }
        send({title: clean(songLink.textContent), artist, pageURL: url.origin + path, lrc: ''});
      }, true);
      document.addEventListener('DOMContentLoaded', detail);
      detail();
    })();
    """#
}

@MainActor
final class FiveSingMessageBridge: NSObject, WKScriptMessageHandler {
    weak var owner: FiveSingBrowser?
    init(owner: FiveSingBrowser) { self.owner = owner }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame,
              let host = message.frameInfo.request.url?.host,
              ["5sing.kugou.com", "search.5sing.kugou.com"].contains(host),
              let body = message.body as? [String: String], let title = body["title"], !title.isEmpty,
              let rawURL = body["pageURL"], let url = URL(string: rawURL), url.host == "5sing.kugou.com",
              ["http", "https"].contains(url.scheme ?? ""),
              url.path.range(of: #"^/(bz|fc|yc)/\d+\.html$"#, options: .regularExpression) != nil else { return }
        owner?.receiveMetadata(FiveSingMetadata(title: String(title.prefix(200)), artist: String((body["artist"] ?? "").prefix(200)),
                                                pageURL: url, lrc: body["lrc"].map { String($0.prefix(100_000)) }))
    }
}
