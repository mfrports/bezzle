import Foundation
import CBezzleHost

// From Bezzle/Import/WebBrowser.swift, for Windows: Bezzle's own browser, for the screens of a web
// app that a plain import cannot reach. Where the Mac keeps one WKWebView and moves it between its
// window and a window out of sight, Windows keeps one WebView2 on the app's own thread
// (CBezzleHost/webview.cpp, bz_web_open_shown), placed in the browser's window under its bar (the
// app's BrowserWindow.swift) or out of sight in a cloaked window of its own while a page is read or
// an assistant browses. It is spoken to through the DevTools protocol as pages read are
// (WebCapture), its hands are the Mac's (WebPageHands.js), and what it works out without asking a
// browser is the Mac's own (WebPages.swift: the pages offered, the artboards' names and places).

/// Bezzle's own browser, for the screens of a web app that a plain import cannot reach: those
/// behind a sign-in, or a click or two away from any address. A person signs in and clicks
/// through in its window and imports the page as it shows it, open menus, results and all, its
/// scrolling boxes scrolled where they are (`importShown`); an assistant does the same through the
/// AI server (`browse`), the window out of sight. Each page comes into a design beside what is
/// there (`WindowsCore.bringIn`).
///
/// Its sign-ins are kept where web imports keep theirs (Bezzle's own WebView2 profile), so they
/// hold for plain imports too, and from one launch to the next.
@MainActor
public final class WebBrowser {
    public static let shared = WebBrowser()

    enum Failure: LocalizedError {
        case nothingOpen
        case page(String)
        case gone

        var errorDescription: String? {
            switch self {
            case .nothingOpen: String(localized: "The browser has no page open.")
            case .page(let why): why
            case .gone: String(localized: "The design to bring the page into is closed.")
            }
        }
    }

    /// What a page brought in became: artboards of a design.
    struct Brought {
        let slot: WindowsCore.Slot
        let ids: [UUID]
        let report: ImportReport
        /// Pages asked for that could not be read, and so are not among them.
        var missed: [URL] = []
    }

    /// What the app's window does for the browser.
    public struct Window {
        /// Puts the window on screen, brought to the front or not; it then says where its page
        /// goes (`place(in:)`).
        public var present: (_ activate: Bool) -> Void = { _ in }
        /// Takes it off the screen.
        public var dismiss: () -> Void = {}
        /// Something it shows changed: the bar, the title, the list of pages.
        public var changed: () -> Void = {}
        /// The size the page is laid out at changed: the window fits it again, and says where.
        public var layOut: () -> Void = {}
        /// A picture of the page to hold in its place while the page is away, or nil when it is back.
        public var still: (Still?) -> Void = { _ in }
        /// A new design made of pages, to open in a tab behind the browser, saying what came across;
        /// the design open, or nil.
        public var opened: @MainActor (URL, WindowsCore.ImportSummary?) async -> WindowsCore.Slot? = { _, _ in nil }
        /// Pages came into an open design: its window shows them, selected, and says what came across.
        public var broughtIn: (WindowsCore.Slot, [UUID], WindowsCore.ImportSummary) -> Void = { _, _, _ in }
        /// Where new designs are kept.
        public var designsFolder: () -> URL = { FileManager.default.temporaryDirectory }

        public init() {}
    }

    public var window = Window()

    /// A picture of the page as the window showed it: its pixels, blue, green, red and alpha,
    /// premultiplied, rows top first, as a WinUI bitmap keeps them.
    public struct Still: Sendable {
        public let width: Int
        public let height: Int
        public let bgra: [UInt8]
    }

    /// A page offered in the list of pages, as the window shows it.
    public struct Listed {
        public enum Kind { case open, visited, linked }
        public let id: String
        public let name: String
        /// Its address's path, or the file's name.
        public let detail: String
        public let kind: Kind
    }

    /// The width the page is laid out at, and the height of the window it is read in.
    private(set) var size: WebCapture.Size = .desktop
    public private(set) var url: URL?
    public private(set) var title = ""
    public private(set) var canGoBack = false
    public private(set) var canGoForward = false
    public private(set) var loading = false
    /// While the page is being brought in: what is being done, and how far it has come, 0…1.
    public private(set) var stage: String?
    public private(set) var progress: Double?
    /// What went wrong the last time, until the next try.
    public private(set) var failure: String?
    /// For a moment after a page came in, so the button can say so.
    public private(set) var justImported = false
    /// Whether its window is on screen for a person.
    public private(set) var shown = false
    /// The address in the window's address field, as typed.
    public var typed = ""
    /// The design pages are brought into; nil for a new one, made with the first page.
    weak var destination: WindowsCore.Slot? { didSet { changed() } }

    public var importing: Bool { progress != nil }
    public var canImport: Bool { url != nil && !importing && !loading }
    /// The design pages go into, while it is open.
    var target: WindowsCore.Slot? { destination.flatMap { $0.isOpen ? $0 : nil } }
    public var destinationName: String? { target?.url?.deletingPathExtension().lastPathComponent }
    /// The width the page is laid out at, and the height it is read at, in CSS pixels.
    public var width: WindowsCore.WebWidth { WindowsCore.WebWidth(Double(size.width)) }
    public var pageHeight: Double { Double(size.height) }

    /// The browser's web view in CBezzleHost, 0 before it is made.
    private var view: Int32 = 0
    private var making: Task<Int32, Error>?
    /// What speaks to the page (WebCapture adopting the view): its hands, its pictures.
    private var speaker: WebCapture?
    /// Where the window shows the page: its window, the page's place in it, and its scale.
    private var spot: (window: UInt, x: Double, y: Double, height: Double, scale: Double)?
    /// How many things hold the page away from the window (a page being read, the list of pages).
    private var covers = 0
    private var placing: Task<Void, Never>?
    private var idle: Task<Void, Never>?
    private var work: Task<Void, Never>?
    /// The load whose failure was last said, by how many loads had begun, so it is said once.
    private var failureSaid: Int32 = 0
    private var failureThrown: Int32 = 0

    /// No scroll bars, which would take room from the page and show in what is photographed (the
    /// Mac's noBars), given a root to go in when the page has none yet, as WebView2 runs it.
    static let noBars = """
        (() => {
          const bars = document.createElement('style');
          bars.textContent = 'html, * { scrollbar-width: none !important; } ::-webkit-scrollbar { display: none !important; width: 0 !important; height: 0 !important; }';
          const root = document.head || document.documentElement;
          if (root) { root.appendChild(bars); return; }
          new MutationObserver((_, watch) => {
            const now = document.head || document.documentElement;
            if (!now) return;
            now.appendChild(bars);
            watch.disconnect();
          }).observe(document, { childList: true, subtree: true });
        })();
        """
    /// What the browser's page is given before its own scripts: no scroll bars, and the recorder
    /// of its WebGL (WebPageGL.js), so it runs as it does in any browser but is laid out as wide
    /// as it is read.
    static let atStart = "if (window === window.top) {\n" + noBars + "\n}\n" + WebCapture.recorder

    init() {}

    // MARK: The page

    /// The web view, made the first time, on the app's thread: out of sight until the window
    /// says where it goes.
    private func webView() async throws -> Int32 {
        if view != 0 { return view }
        if let making { return try await making.value }
        let size = self.size
        let task = Task<Int32, Error> {
            guard bz_web_host_here() == 0 else { throw WebCapture.Failure.load(String(localized: "the page stopped working.")) }
            let width = Int32(size.width), height = Int32(size.height)
            let agent = size.mobile ? WebCapture.mobileAgent : WebCapture.desktopAgent, scripts = Self.atStart
            let made = await Self.off { bz_web_open_shown(width, height, 0, agent, scripts) }
            guard made != 0 else {
                let why = await Self.off { () -> String in
                    let text = bz_web_error()
                    defer { bz_web_free(text) }
                    return text.map { String(cString: $0) } ?? ""
                }
                throw WebCapture.Failure.load(why)
            }
            return made
        }
        making = task
        defer { making = nil }
        let made = try await task.value
        if view == 0 {
            view = made
            speaker = WebCapture(adopting: made)
            bz_web_watch(made, browserChanged)
            relocate()
        }
        return view
    }

    func followed(_ id: Int32) {
        guard id == view, view != 0 else { return }
        let text = bz_web_page(id)
        defer { bz_web_free(text) }
        guard let text, let object = (try? JSONSerialization.jsonObject(with: Data(String(cString: text).utf8))) as? [String: Any] else { return }
        let was = url, wasLoading = loading
        let address = object["url"] as? String ?? ""
        url = address.isEmpty || address == "about:blank" ? nil : URL(string: address)
        title = object["title"] as? String ?? ""
        if title == address { title = "" }
        canGoBack = object["back"] as? Bool ?? false
        canGoForward = object["forward"] as? Bool ?? false
        loading = object["loading"] as? Bool ?? false
        if url != was, let url { typed = url.isFileURL ? url.path : url.absoluteString }
        // A new load clears what went wrong; one that failed says so, once, while it is shown.
        if loading && !wasLoading && failure != nil && !importing { failure = nil }
        let now = state()
        if now.state == 2, !loading, now.navigations != failureSaid {
            failureSaid = now.navigations
            if shown { failure = WebCapture.Failure.load(WebCapture.why(now.error)).localizedDescription }
        }
        changed()
    }

    private func state() -> (state: Int32, error: Int32, navigations: Int32) {
        var status: Int32 = 0, error: Int32 = 0, navigations: Int32 = 0
        let state = bz_web_state(view, &status, &error, &navigations)
        return (state, error, navigations)
    }

    /// The web view of the page open, or why there is none.
    private func page() throws -> Int32 {
        guard view != 0, url != nil else { throw Failure.nothingOpen }
        return view
    }

    /// Opens a page and waits until it has loaded and settled.
    func open(_ url: URL) async throws {
        if url.isFileURL, !FileManager.default.fileExists(atPath: url.path) {
            throw WebCapture.Failure.load(String(localized: "There is no such file."))
        }
        let view = try await webView()
        touch()
        let before = state().navigations
        failureThrown = before
        let address = url.absoluteString
        guard await Self.off({ bz_web_load(view, address, 0) }) == 0 else { throw WebCapture.Failure.load(String(localized: "the page stopped working.")) }
        let begun = Date()
        while state().navigations == before && Date().timeIntervalSince(begun) < 3 { try await Task.sleep(for: .milliseconds(40)) }
        try await settle(most: 30)
    }

    /// Goes to what was typed into the address field.
    public func go(_ typed: String) {
        guard let url = WebCapture.address(typed) else {
            fail(String(localized: "That is not a web address Bezzle can open."))
            return
        }
        fail(nil)
        run { try await self.open(url) }
    }

    public func back() { step(1) }
    public func forward() { step(2) }
    public func reload() { step(3) }

    private func step(_ what: Int32) {
        guard view != 0 else { return }
        let view = self.view
        touch()
        Task { _ = await Self.off { bz_web_go(view, what) } }
    }

    /// Waits for what a step set going: the page loading, then a moment with nothing changing.
    func settle(most: TimeInterval = 20) async throws {
        guard view != 0 else { return }
        let begun = Date()
        try await Task.sleep(for: .milliseconds(120))
        while true {
            let now = state()
            if now.state == 3 { throw WebCapture.Failure.load(String(localized: "the page stopped working.")) }
            if now.state == 2, !loading, now.navigations != failureThrown {
                failureThrown = now.navigations
                throw WebCapture.Failure.load(WebCapture.why(now.error))
            }
            if !loading || Date().timeIntervalSince(begun) >= most { break }
            try await Task.sleep(for: .milliseconds(80))
        }
        _ = try? await hands("return await __bezzleHands.settle(still, most)", ["still": 350, "most": 6000])
    }

    /// Lays the page out at another size: a phone's tells the page so, and is loaded again.
    public func resize(to width: WindowsCore.WebWidth) { resize(to: width.size) }

    func resize(to size: WebCapture.Size) {
        let phone = size.mobile != self.size.mobile
        self.size = size
        if view != 0 {
            let view = self.view, width = Int32(size.width), height = Int32(size.height)
            let agent = size.mobile ? WebCapture.mobileAgent : WebCapture.desktopAgent, reload = phone && url != nil
            Task {
                _ = await Self.off { bz_web_resize(view, width, height, agent) }
                if reload { _ = await Self.off { bz_web_go(view, 3) } }
            }
        }
        window.layOut()
        relocate()
        changed()
    }

    // MARK: Where the page is

    /// Where the window shows the page, in its own coordinates (CSS pixels from its top left,
    /// `scale` device pixels each): the window says so when it is laid out.
    public func place(in hwnd: UInt, x: Double, y: Double, height: Double, scale: Double) {
        spot = (hwnd, x, y, height, scale)
        relocate()
    }

    /// The page in the window, when the window shows it and nothing holds it away, otherwise out of
    /// sight at its full size; one move after another.
    private func relocate() {
        let previous = placing
        placing = Task {
            await previous?.value
            guard view != 0 else { return }
            let view = self.view, width = Int32(size.width)
            if shown, covers == 0, let spot {
                let height = Int32(spot.height.rounded())
                _ = await Self.off { bz_web_place(view, UnsafeMutableRawPointer(bitPattern: spot.window), spot.x, spot.y, width, height, spot.scale) }
            } else {
                let height = Int32(size.height), scale = spot?.scale ?? 0
                _ = await Self.off { bz_web_place(view, nil, 0, 0, width, height, scale) }
            }
        }
    }

    /// Holds the page away from the window, a picture of it in its place, or lets it back: while a
    /// page is read at its full size, and while the list of pages lies over it (a page in a window
    /// is drawn over all else there).
    public func cover(_ on: Bool) async {
        if on {
            covers += 1
            guard covers == 1, view != 0 else { return }
            if shown { window.still(await still()) }
            relocate()
            await placing?.value
        } else {
            covers = max(0, covers - 1)
            guard covers == 0 else { return }
            relocate()
            await placing?.value
            window.still(nil)
        }
    }

    /// The keyboard to the page.
    public func focusPage() {
        guard view != 0 else { return }
        let view = self.view
        Task { _ = await Self.off { bz_web_go(view, 5) } }
    }

    // MARK: Hands, for an assistant

    /// The page as an assistant is told of it, as JSON: its address and title, how far it is
    /// scrolled, what one can press or fill in, numbered, its dialogs and menus, and its words.
    func look(words: Int? = nil) async throws -> String {
        _ = try page()
        touch()
        guard let json = try await hands("return __bezzleHands.look(opts)", ["opts": ["words": words ?? 3000]]) as? String,
              var object = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] else { throw Failure.page("The page could not be looked at.") }
        object["window"] = shown ? "shown to the person" : "out of sight"
        object["into"] = destinationName
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    /// What `target` names: a number from the last look, or words on the thing; or `selector`.
    private func aim(_ target: Any?, _ selector: String?) -> [String: Any] {
        ["target": target ?? NSNull(), "selector": selector ?? NSNull()]
    }

    func click(_ target: Any?, selector: String? = nil) async throws -> String {
        try await act("return __bezzleHands.click(target, selector)", aim(target, selector))
    }

    func hover(_ target: Any?, selector: String? = nil) async throws -> String {
        try await act("return __bezzleHands.hover(target, selector)", aim(target, selector))
    }

    /// Types words into a field, in place of what is in it unless `add`; never into a password.
    func type(_ text: String, into target: Any?, selector: String? = nil, submit: Bool = false, add: Bool = false) async throws -> String {
        var args = aim(target, selector)
        args["text"] = text
        args["submit"] = submit
        args["add"] = add
        return try await act("return __bezzleHands.type(target, selector, text, submit, add)", args)
    }

    func press(_ key: String) async throws -> String {
        try await act("return __bezzleHands.press(key)", ["key": key])
    }

    /// Scrolls a thing into view, or the page to "top", "bottom" or a height, or by a distance.
    func scroll(_ target: Any?, selector: String? = nil, to: Any? = nil, by: Double? = nil) async throws -> String {
        var args = aim(target, selector)
        args["to"] = to ?? NSNull()
        args["by"] = by ?? NSNull()
        return try await act("return __bezzleHands.scroll(target, selector, to, by)", args)
    }

    private func act(_ body: String, _ args: [String: Any]) async throws -> String {
        _ = try page()
        touch()
        let said = try await hands(body, args) as? String ?? ""
        try await settle()
        return said
    }

    /// Calls the hands in their world, putting them there first when the page came in before
    /// they could be.
    private func hands(_ body: String, _ args: [String: Any]) async throws -> Any? {
        guard view != 0, let speaker else { throw Failure.nothingOpen }
        do {
            return try await speaker.hands(body, args)
        } catch WebCapture.Failure.said(let what) {
            throw Failure.page(what)
        } catch let error as WebCapture.Failure {
            throw Failure.page(error.localizedDescription)
        }
    }

    /// What the window shows of the page, as a PNG no wider than 1440 pixels.
    func picture() async throws -> Data? {
        _ = try page()
        guard let speaker, let json = try await speaker.inPage("JSON.stringify([scrollX, scrollY, innerWidth, innerHeight, devicePixelRatio])") as? String,
              let m = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [Double], m.count == 5, m[2] > 0, m[3] > 0 else { return nil }
        let scale = min(m[2], 1440) / m[2] / max(m[4], 0.25)
        let answer = try await speaker.ask("Page.captureScreenshot", ["format": "png", "fromSurface": true, "captureBeyondViewport": false,
                                                                      "clip": ["x": m[0], "y": m[1], "width": m[2], "height": m[3], "scale": scale]])
        return (answer["data"] as? String).flatMap { Data(base64Encoded: $0) }
    }

    /// The page as the window shows it, to hold in its place.
    private func still() async -> Still? {
        guard let speaker, let json = try? await speaker.inPage("JSON.stringify([scrollX, scrollY, innerWidth, innerHeight])") as? String,
              let m = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [Double], m.count == 4, m[2] > 0, m[3] > 0,
              let answer = try? await speaker.ask("Page.captureScreenshot", ["format": "png", "fromSurface": true, "captureBeyondViewport": false,
                                                                            "clip": ["x": m[0], "y": m[1], "width": m[2], "height": m[3], "scale": 1]]),
              let encoded = answer["data"] as? String, let data = Data(base64Encoded: encoded) else { return nil }
        return await Self.off { () -> Still? in
            guard var photo = WebCapture.Photo.decoded(data) else { return nil }
            // Red and blue change places: WinUI keeps blue first.
            photo.bytes.withUnsafeMutableBufferPointer { p in
                var k = 0
                while k + 3 < p.count {
                    p.swapAt(k, k + 2)
                    k += 4
                }
            }
            return Still(width: photo.width, height: photo.height, bgra: photo.bytes)
        }
    }

    // MARK: Bringing the page in

    /// Reads the page as it is now, signed in, clicked through and typed into, and brings it in:
    /// into `slot`, or else the design the last page went into, or else a new design, which
    /// the pages after it go into too. The page is left as it was.
    @discardableResult
    func importShown(name: String? = nil, into slot: WindowsCore.Slot? = nil) async throws -> Brought {
        _ = try page()
        try begin()
        defer { end() }
        var (read, held) = try await readShown { [weak self] what, done in self?.say(what, done) }
        read.name = Self.given(name) ?? WebImport.boardName(of: read.page, size: size, among: nodes(of: slot ?? target))
        return try await bring([read], held: held, into: slot)
    }

    /// Brings several pages in at once, side by side in one design and one step of its undo
    /// history: the page open as it shows now, and the others loaded one after another out of
    /// sight, signed in as the browser is, while the page open stays as it is. A page that cannot
    /// be read is left out and said so (`Brought.missed`).
    @discardableResult
    func importPages(_ chosen: [WebSitePage], into slot: WindowsCore.Slot? = nil) async throws -> Brought {
        _ = try page()
        guard !chosen.isEmpty else { throw Failure.page(String(localized: "Choose the pages to import.")) }
        try begin()
        done = []
        defer {
            reading = nil
            end()
        }
        let capture = WebCapture()
        defer { capture.close() }
        var reads: [WebRead] = [], held: [String: Data] = [:], missed: [URL] = []
        var named = nodes(of: slot ?? target)
        let here = url.map(WebSitePage.plain)
        for (i, page) in chosen.enumerated() {
            try Task.checkCancellation()
            reading = page.id
            changed()
            let lead = chosen.count > 1 ? String(localized: "Page \(i + 1) of \(chosen.count)") + ": " : ""
            let tell: (String, Double) -> Void = { [weak self] what, part in
                self?.say(lead + what, (Double(i) + part) / Double(chosen.count))
            }
            do {
                var (read, pictures): (WebRead, [String: Data])
                if WebSitePage.plain(page.url) == here {
                    (read, pictures) = try await readShown(tell)
                } else {
                    capture.progress = tell
                    (read, pictures) = try await capture.read(page.url, size: size)
                }
                read.name = WebImport.boardName(of: read.page, size: size, among: named)
                named.append(Node(kind: .artboard, name: read.name, frame: .zero))
                reads.append(read)
                held.merge(pictures) { a, _ in a }
                done.insert(page.id)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                missed.append(page.url)
            }
        }
        guard !reads.isEmpty else { throw Failure.page(String(localized: "None of the pages could be read.")) }
        var brought = try await bring(reads, held: held, into: slot)
        brought.missed = missed
        if !missed.isEmpty { fail(String(localized: "\(missed.count) pages could not be read.")) }
        return brought
    }

    /// The page as it is in the browser, read out of sight at its full size while the window
    /// holds a picture of it still, and left as it was.
    private func readShown(_ tell: @escaping (String, Double) -> Void) async throws -> (WebRead, [String: Data]) {
        let view = try page()
        await cover(true)
        let capture = WebCapture(adopting: view)
        capture.progress = tell
        do {
            try await Task.sleep(for: .milliseconds(150))
            let read = try await capture.readAsShown(size: size)
            capture.close()
            await cover(false)
            return read
        } catch {
            capture.close()
            await cover(false)
            throw error
        }
    }

    /// The layers of an open design, to name new artboards apart from.
    private func nodes(of slot: WindowsCore.Slot?) -> [Node] {
        guard let slot, slot.isOpen else { return [] }
        return WindowsCore.using(slot) { WindowsCore.design?.nodes ?? [] }
    }

    /// Pages read, brought into `slot`, or else the design the last pages went into, or else a
    /// new design, opened behind the browser, which the pages after them go into too.
    private func bring(_ reads: [WebRead], held: [String: Data], into slot: WindowsCore.Slot?) async throws -> Brought {
        let source = WebImport.source(of: url ?? URL(fileURLWithPath: "/"))
        if let into = slot ?? destination {
            guard into.isOpen else { throw Failure.gone }
            let (ids, report) = try WindowsCore.using(into) { try WindowsCore.bringIn(reads, held: held, source: source) }
            destination = into
            window.broughtIn(into, ids, WindowsCore.summary(of: report))
            imported()
            return Brought(slot: into, ids: ids, report: report)
        }
        let (design, report) = try WebImport.write(reads, held: held, source: source, into: window.designsFolder())
        guard let made = await window.opened(design, report.lines.isEmpty ? nil : WindowsCore.summary(of: report)), made.isOpen else { throw Failure.gone }
        try Task.checkCancellation()
        if destination == nil { destination = made }
        imported()
        let ids = WindowsCore.using(made) { WindowsCore.design?.nodes.filter(\.isArtboard).map(\.id) ?? [] }
        return Brought(slot: made, ids: ids, report: report)
    }

    private func begin() throws {
        guard !importing else { throw Failure.page(String(localized: "A page is already being brought in.")) }
        touch()
        fail(nil)
        stage = String(localized: "Scrolling through the page…")
        progress = 0.02
        changed()
    }

    private func end() {
        stage = nil
        progress = nil
        touch()
        changed()
    }

    private func say(_ what: String, _ part: Double) {
        stage = what
        progress = max(progress ?? 0, part * 0.95)
        changed()
    }

    private static func given(_ name: String?) -> String? {
        name.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
    }

    // MARK: Pages

    /// The pages offered, the one open first, then those visited, then those it links to.
    private(set) var pages: [WebSitePage] = []
    /// Those chosen to be brought in, by id.
    public var chosen: Set<String> = []
    /// While pages are brought in: the one being read, and those read.
    public private(set) var reading: String?
    public private(set) var done: Set<String> = []

    /// The pages offered, as the list shows them.
    public var listed: [Listed] {
        pages.map { p in
            let kind: Listed.Kind = switch p.kind { case .open: .open; case .visited: .visited; case .linked: .linked }
            let detail = p.url.isFileURL ? p.url.lastPathComponent : p.url.path + (p.url.query.map { "?" + $0 } ?? "")
            return Listed(id: p.id, name: p.name, detail: detail, kind: kind)
        }
    }

    /// Finds the pages to offer: the one open, those visited in the browser, newest first, and
    /// those the page links to, each once. Only the open page is chosen at first.
    @discardableResult
    public func findPages() async -> Int {
        await offered().count
    }

    @discardableResult
    func offered() async -> [WebSitePage] {
        guard view != 0, let here = url, let speaker else {
            pages = []
            changed()
            return []
        }
        // WebView2's history, as the DevTools protocol lists it: the oldest first, and which is open.
        var visited: [(url: URL, title: String?)] = []
        if let history = try? await speaker.ask("Page.getNavigationHistory", [:]), let entries = history["entries"] as? [[String: Any]],
           let at = WebCapture.number(history["currentIndex"]).map(Int.init), entries.indices.contains(at) {
            func entry(_ e: [String: Any]) -> (url: URL, title: String?)? {
                guard let address = e["url"] as? String, let to = URL(string: address) else { return nil }
                return (to, e["title"] as? String)
            }
            visited = entries[..<at].reversed().compactMap(entry) + entries[(at + 1)...].compactMap(entry)
        }
        let links = try? await hands("return __bezzleHands.pages(opts)", ["opts": ["limit": 200]]) as? String
        let found = WebSitePage.offered(open: here, title: title, visited: visited, links: links)
        pages = found
        chosen = chosen.intersection(found.map(\.id))
        if chosen.isEmpty { chosen = [found[0].id] }
        changed()
        return found
    }

    /// The person's Import button in the list of pages: those chosen, into the design chosen.
    public func importChosen() {
        let chosen = pages.filter { self.chosen.contains($0.id) }
        guard !chosen.isEmpty, !importing else { return }
        run { try await self.importPages(chosen) }
    }

    /// Stops pages being brought in; those read so far are not brought in.
    public func cancelWork() {
        work?.cancel()
    }

    private func imported() {
        justImported = true
        changed()
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.6))
            self?.justImported = false
            self?.changed()
        }
    }

    /// The person's Import button: the page into the design chosen, saying what went wrong.
    public func importFromWindow() {
        guard canImport else { return }
        run { try await self.importShown() }
    }

    private func run(_ job: @escaping () async throws -> Void) {
        work?.cancel()
        work = Task { [weak self] in
            do { try await job() } catch is CancellationError {
            } catch {
                self?.fail((error as? LocalizedError)?.errorDescription ?? "\(error)")
            }
        }
    }

    // MARK: Windows

    /// Puts the browser's window on screen for a person, at `address` if one is given, bringing
    /// pages into `slot`, or a new design when none is.
    public func show(_ address: URL? = nil, width: WindowsCore.WebWidth? = nil, into slot: WindowsCore.Slot?, activate: Bool = true) {
        show(address, size: width?.size, into: slot, activate: activate)
    }

    func show(_ address: URL?, size: WebCapture.Size?, into slot: WindowsCore.Slot?, activate: Bool) {
        destination = slot
        if let size { resize(to: size) }
        shown = true
        window.present(activate)
        changed()
        Task { [weak self] in
            do {
                _ = try await self?.webView()
                self?.relocate()
            } catch {
                self?.fail((error as? LocalizedError)?.errorDescription ?? "\(error)")
            }
        }
        if let address { run { try await self.open(address) } }
    }

    /// Takes the window off the screen; the page stays open out of sight for an assistant.
    public func hide() {
        window.dismiss()
        windowClosed()
    }

    /// Lets go of the page and its window. Its sign-ins stay.
    func close() {
        work?.cancel()
        idle?.cancel()
        window.dismiss()
        shown = false
        let v = view
        view = 0
        speaker = nil
        if v != 0 { DispatchQueue.global(qos: .utility).async { bz_web_close(v) } }
        url = nil
        title = ""
        loading = false
        canGoBack = false
        canGoForward = false
        pages = []
        changed()
    }

    /// Bezzle is quitting: the page is let go at once, on the app's thread, so WebView2 keeps what
    /// it stored (the sign-ins) as it ends.
    public func quitting() {
        work?.cancel()
        idle?.cancel()
        let v = view
        view = 0
        speaker = nil
        if v != 0 { bz_web_close(v) }
    }

    /// The window was closed by the person: the page goes out of sight, still open.
    public func windowClosed() {
        shown = false
        relocate()
        touch()
        changed()
    }

    private func fail(_ message: String?) {
        failure = message
        changed()
    }

    private func changed() { window.changed() }

    /// Keeps the page awake while it is used, and lets it go when it has not been for a while:
    /// closed after twenty minutes, its window not shown.
    private func touch() {
        idle?.cancel()
        idle = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20 * 60))
            guard let self, !Task.isCancelled, !self.shown, !self.importing else { return }
            self.close()
        }
    }

    /// Runs `work`, which waits for WebView2, on a thread of its own, not the main one.
    nonisolated private static func off<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { (done: CheckedContinuation<T, Never>) in
            DispatchQueue.global(qos: .userInitiated).async { done.resume(returning: work()) }
        }
    }
}

/// What CBezzleHost tells, on the app's thread, when the browser's page may have changed.
nonisolated private func browserChanged(_ id: Int32) {
    MainActor.assumeIsolated { WebBrowser.shared.followed(id) }
}
