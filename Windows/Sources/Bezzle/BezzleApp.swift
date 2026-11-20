import Foundation
import WinSDK
import CWinAppSDK
import WinUI
import WinAppSDK
import WindowsFoundation
import BezzleCore
import UWP

/// Starts Bezzle: the Windows App Runtime, then WinUI with Bezzle's application.
///
/// Not SwiftApplication's own `main`, which finds the application class by name (that fails for a
/// class in an executable), nor WindowsAppRuntimeInitializer, which looks for the runtime's
/// bootstrapper in a resource folder Foundation no longer finds: the bootstrapper sits beside
/// Bezzle.exe (build.ps1 puts it there), as in an installed copy.
@main
enum Main {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.first == HomePreviewWorker.command {
            let result = MainActor.assumeIsolated { HomePreviewWorker.run(arguments) }
            exit(result)
        }
        Trace.time("main")
        // A second start of this Bezzle.exe gives what it was asked to open to the one running,
        // which opens it in tabs, and goes (HandOver).
        if HandOver.pass(arguments) { return }
        do {
            try startRuntime()
            Trace.time("Windows App Runtime started")
            var application: BezzleApp?
            let exitCode = try Application.startWithCustomRunLoop(BezzleApp.runLoop) { _ in
                application = BezzleApp()
            }
            application?.onShutdown(exitCode: exitCode)
        } catch {
            fatalError("Bezzle could not start WinUI: \(error)")
        }
    }

    private typealias Initialize = @convention(c) (UInt32, PCWSTR?, PACKAGE_VERSION, MddBootstrapInitializeOptions) -> HRESULT

    /// The Windows App Runtime that the bindings were made for (an unpackaged app finds it through
    /// the bootstrapper), on a single-threaded Windows Runtime apartment.
    private static func startRuntime() throws {
        let initialized = RoInitialize(RO_INIT_SINGLETHREADED)
        guard initialized >= 0 else { throw RuntimeError(step: "RoInitialize", result: initialized) }
        // OLE as well, as an app's own main would start it (C#'s [STAThread] does): without it,
        // nothing dragged in from Explorer reaches the window.
        _ = OleInitialize(nil)
        let folder = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        let path = folder.appendingPathComponent("Microsoft.WindowsAppRuntime.Bootstrap.dll").path
        guard let dll = path.withCString(encodedAs: UTF16.self, LoadLibraryW),
              let function = GetProcAddress(dll, "MddBootstrapInitialize2") else {
            throw RuntimeError(step: "loading \(path)", result: HRESULT(bitPattern: GetLastError()))
        }
        let result = unsafeBitCast(function, to: Initialize.self)(
            UInt32(WINDOWSAPPSDK_RELEASE_MAJORMINOR), WINDOWSAPPSDK_RELEASE_VERSION_TAG_SWIFT, PACKAGE_VERSION(),
            MddBootstrapInitializeOptions(MddBootstrapInitializeOptions_OnNoMatch_ShowUI.rawValue))
        guard result >= 0 else { throw RuntimeError(step: "MddBootstrapInitialize2", result: result) }
    }

    struct RuntimeError: Swift.Error, CustomStringConvertible {
        let step: String
        let result: HRESULT
        var description: String { "\(step) failed: 0x" + String(UInt32(bitPattern: result), radix: 16) }
    }
}

/// Whether AI assistants may work in the app (the AI server); on unless turned off in the
/// Bezzle menu, as on the Mac, under the Mac's own key.
@MainActor enum AIControl {
    static var allowed: Bool {
        get { UserDefaults.standard.object(forKey: "aiControl") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "aiControl")
            if newValue { MCPServer.shared.start() } else { MCPServer.shared.stop() }
        }
    }
}

/// Bezzle on Windows: one window with its own tabs, home and a tab for each open design, as on
/// the Mac (Tabs.swift). This is the window: its pages, its size, closing it, and quitting.
final class BezzleApp: SwiftApplication {
    var window: Window?
    /// Home's page, made again when the designs folder changes.
    private var home: HomeView?
    /// The page in the window now.
    private var presented: TabPage?
    /// What the window holds: the page, and over it, under the bar, the cover of a design on its
    /// way into its tab (OpeningCover.swift).
    private lazy var frame = Grid()
    private lazy var coverLayer = Grid()
    /// Whether the window holds the frame yet, and the cover in it.
    private var framed = false
    private weak var shownCover: OpeningCover?
    /// The window's own presenter, which says whether it can be resized.
    private var presenter: OverlappedPresenter?
    /// Set as Bezzle quits, when the window may close.
    private var quitting = false

    /// Where designs are kept: the folder chosen in the Bezzle menu (Designs Folder…), or, as the
    /// Mac's standard one, Documents › Bezzle.
    static var designsFolder: URL {
        // A test copy beside the one in use keeps to a folder of its own (BEZZLE_DESIGNS_FOLDER),
        // as the settings are every copy's.
        if let test = ProcessInfo.processInfo.environment["BEZZLE_DESIGNS_FOLDER"], !test.isEmpty {
            return URL(fileURLWithPath: test, isDirectory: true)
        }
        #if DEBUG
        // BEZZLE_DESIGNS: a test copy's own, away from the person's designs.
        if let given = ProcessInfo.processInfo.environment["BEZZLE_DESIGNS"], !given.isEmpty { return URL(fileURLWithPath: given, isDirectory: true) }
        #endif
        // BEZZLE_LIBRARY, as on the Mac, keeps a test copy's designs apart from everyone's.
        if let test = ProcessInfo.processInfo.environment["BEZZLE_LIBRARY"], !test.isEmpty { return URL(fileURLWithPath: test, isDirectory: true) }
        if let chosen = UserDefaults.standard.string(forKey: "designsFolderPath"), FileManager.default.fileExists(atPath: chosen) {
            return URL(fileURLWithPath: chosen, isDirectory: true)
        }
        return (FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? FileManager.default.homeDirectoryForCurrentUser)
            .appendingPathComponent("Bezzle", isDirectory: true)
    }

    /// Another folder chosen to keep designs in, as the Mac's Designs Folder…; home shows it.
    @MainActor func chooseDesignsFolder() {
        guard let folder = FileDialogs.chooseFolder(title: Words.t("Designs Folder…"), button: Words.t("Choose"), startingIn: Self.designsFolder) else { return }
        UserDefaults.standard.set(folder.path, forKey: "designsFolderPath")
        home = makeHome()
        if Tabs.shared.selectedID == nil { Tabs.shared.showFront() }
    }

    required init() {
        super.init()
    }

    /// Bezzle's own message loop, which sleeps when there is nothing to do (MessageLoop.swift).
    override class var runLoop: SwiftApplication.RunLoop { { queue in MainActor.assumeIsolated { MessageLoop.run(queue) } } }

    override func onLaunched(_ args: WinUI.LaunchActivatedEventArgs) {
        Trace.time("launched")
        // The core's own words (what a drag measures) in the user's language too.
        WindowsCore.say = { key, args in Words.t(key, arguments: args) }
        // The shared code's own words too, such as the names new layers are given.
        Localization.lookup = { key, args in Words.lookup(key, args) }
        // What Foundation does on the Mac that the host does here (the icon library's unpacking).
        MainActor.assumeIsolated { WindowsCore.start() }
        MainActor.assumeIsolated { Theme.readAppearance() }
        WindowsCore.designsFolder = { Self.designsFolder }
        // A picture cut out, here or by the AI, as it goes: the window of its design shows the work,
        // and the design once it changes; one behind another shows it as it comes to the front.
        WindowsCore.cutoutsChanged = { slot, edited in
            let tabs = Tabs.shared
            guard let view = (slot.flatMap { tabs.tab(of: $0) } ?? tabs.activeTab)?.view else { return }
            if edited { view.session.edited(board: nil) } else { view.session.changed() }
            if view.session.isFront { view.canvas.drawCutouts() }
        }
        // A picture vectorized or traced again, here or by the AI, the same way: the pencil's
        // pass on the canvas, quick tracings while a dial turns, and the design once it changes.
        WindowsCore.vectorsChanged = { slot, change in
            let tabs = Tabs.shared
            guard let view = (slot.flatMap { tabs.tab(of: $0) } ?? tabs.activeTab)?.view else { return }
            switch change {
            case .edited: view.session.edited(board: nil)
            case .shown:
                view.session.previewed(board: nil)
                view.session.changed()
            case .work: view.session.changed()
            }
            if view.session.isFront { view.canvas.drawVectors() }
        }
        SubjectModel.log = { Trace.say($0) }
        // A way of making the subject matte that took Bezzle down is passed over by this version,
        // and tried again by the next.
        SubjectModel.appVersion = AppVersion.short
        let window = Window()
        window.title = "Bezzle"
        self.window = window
        // Bezzle draws its own bar, as on the Mac; Windows keeps its caption buttons at its right.
        window.extendsContentIntoTitleBar = true
        if let appWindow = window.appWindow {
            if let presenter = try? OverlappedPresenter.create() {
                try? appWindow.setPresenter(presenter)
                self.presenter = presenter
            }
            if let bar = appWindow.titleBar {
                bar.preferredHeightOption = .tall
                bar.buttonBackgroundColor = UWP.Color(a: 0, r: 0, g: 0, b: 0)
                bar.buttonInactiveBackgroundColor = UWP.Color(a: 0, r: 0, g: 0, b: 0)
                MainActor.assumeIsolated {
                    bar.buttonForegroundColor = Theme.color(Theme.ink)
                    bar.buttonInactiveForegroundColor = Theme.color(Theme.ink, 0.44)
                    bar.buttonHoverBackgroundColor = Theme.color(Theme.ink, 0.06)
                }
            }
            // The close button (and Alt+F4) closes the designs, as the Mac's red button does;
            // only with home in front does Bezzle quit.
            appWindow.closing.addHandler { [weak self] _, args in
                guard let self, !self.quitting else { return }
                args?.cancel = true
                DispatchQueue.main.async { MainActor.assumeIsolated { Tabs.shared.closeWindow() } }
            }
        }
        // Gone without quitting (Windows shutting down): every design saved.
        window.closed.addHandler { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self, !self.quitting else { return }
                Tabs.shared.closeAll()
                SubjectModel.shared.quitting()
            }
        }
        // Back to Bezzle: designs renamed or moved in Explorer meanwhile are followed, as the Mac
        // follows them when it comes forward.
        window.activated.addHandler { _, args in
            guard args?.windowActivationState != .deactivated else { return }
            MainActor.assumeIsolated { Tabs.shared.followFiles() }
        }
        // WinUI calls this on the main thread, where the core lives.
        MainActor.assumeIsolated {
            let fonts = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("fonts")
            do {
                try WindowsCore.loadFonts(from: fonts)
                Trace.time("fonts loaded")
            } catch {
                window.content = message("Bezzle could not read its fonts", detail: "\(error)")
                return
            }
            // bezzle: links open with this copy (Links.swift).
            answerLinks()
            startTabs()
            fitWindow(forDesigns: false, centred: true)
            Tabs.shared.showFront()
            openCommandLine(Array(CommandLine.arguments.dropFirst()), in: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true))
            OpeningCover.openAsAsked()
            // The tour, the first time Bezzle starts with no designs (WelcomeTour.swift).
            WelcomeTour.start()
            // Import from a Website, over the page in front; what it makes opens in a tab with what
            // came across at the canvas's foot, as a design from another app does.
            let web = WebImporting.shared
            web.host = { [weak self] in self?.presented?.root }
            web.folder = { Self.designsFolder }
            web.opened = { made, summary in Tabs.shared.open(made, report: summary) }
            web.broughtIn = { slot, ids, summary in Self.showBrought(ids, in: slot, summary, inView: true) }
            // Bezzle's browser (BrowserWindow.swift): a design it makes opens in a tab behind it,
            // and pages it brings into an open design show there, selected.
            BrowserWindow.shared.connect(opened: { made, summary in
                Tabs.shared.open(made, report: summary)
                return Tabs.shared.tab(showing: made)?.slot
            }, broughtIn: { slot, ids, summary in
                Self.showBrought(ids, in: slot, summary, inView: false)
            }, designsFolder: { Self.designsFolder })
            WindowsCore.webImportLog = { Trace.say($0) }
            // About Bezzle, over the page in front too.
            AboutSheet.shared.host = { [weak self] in self?.presented?.root }
            Trace.time("first view made")
            startAIServer()
            // Later starts of this Bezzle.exe hand over what they were asked to open.
            HandOver.listen { [weak self] arguments, folder in
                self?.openCommandLine(arguments, in: folder)
                self?.bringForward()
            }
        }
        MainActor.assumeIsolated { watchActivation() }
        try? window.activate()
        Trace.time("window activated")
        // Once shown, the window's borders are known, and its size is set exactly.
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.fitWindow(forDesigns: !Tabs.shared.designs.isEmpty, centred: true) }
        }
        // A copy installed from bezzle.ch looks for a new version once it is on screen (Updates.swift).
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { MainActor.assumeIsolated { Updates.start() } }
    }

    /// Pages brought into an open design from the web: drawn and saved, selected, and what came
    /// across said at the canvas's foot, as the Mac's store shows them; `inView`, the design's tab
    /// to the front and the canvas turned to them, as the Mac's sheet does.
    @MainActor static func showBrought(_ ids: [UUID], in slot: WindowsCore.Slot, _ summary: WindowsCore.ImportSummary, inView: Bool) {
        let tabs = Tabs.shared
        guard let tab = tabs.tab(of: slot), let view = tab.view else { return }
        if inView { tabs.select(tab) }
        WindowsCore.using(slot) {
            view.session.edited(board: nil)
            view.session.select(ids, on: ids.first.flatMap(WindowsCore.board(of:)) ?? view.session.board)
        }
        if !summary.lines.isEmpty { view.showImportReport(summary) }
        if inView, !ids.isEmpty { view.canvas.fitSelection() }
    }

    // MARK: The command line

    /// What Bezzle was asked to open as it started, or by a later start that handed it over
    /// (`HandOver`): each design named, and each file from another app, in a tab of its own, as
    /// the Finder's files open on the Mac. The one place a command line is opened; names relative
    /// to the folder it was started in are found there.
    @MainActor func openCommandLine(_ arguments: [String], in folder: URL) {
        for argument in arguments {
            let text = argument.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if WindowsCore.isShareLink(text) || text.lowercased().hasPrefix("bezzle:") {
                openLink(text)
                continue
            }
            let url: URL
            if text.lowercased().hasPrefix("file:"), let file = URL(string: text), file.isFileURL {
                url = file
            } else if Self.isAbsolute(text) {
                url = URL(fileURLWithPath: text)
            } else {
                url = folder.appendingPathComponent(text)
            }
            Tabs.shared.open(url.standardizedFileURL)
        }
    }

    /// A link to a design someone shared (bezzle://share/2.…, or Bezzle's page on the web with
    /// #2.… after it), from the command line: a bezzle: link opened in a browser or elsewhere
    /// starts Bezzle with it. Accepting it is sharing's (Host/Linking.swift, `acceptLink`), which
    /// joins here.
    @MainActor func openLink(_ link: String) {
        openShareLink(link)
    }

    private static func isAbsolute(_ path: String) -> Bool {
        let s = Array(path.unicodeScalars)
        if s.count >= 3, s[1] == ":", s[2] == "\\" || s[2] == "/" { return true }
        return path.hasPrefix("\\\\") || path.hasPrefix("/")
    }

    /// The window to the front, as the Mac's does when a design opens from the Finder.
    @MainActor private func bringForward() {
        guard let id = window?.appWindow?.id, let hwnd = HWND(bitPattern: UInt(id.value)) else { return }
        if IsIconic(hwnd) { ShowWindow(hwnd, SW_RESTORE) }
        SetForegroundWindow(hwnd)
    }

    // MARK: The tabs

    @MainActor private func startTabs() {
        let tabs = Tabs.shared
        home = makeHome()
        tabs.home = { [weak self] in self?.home }
        tabs.present = { [weak self] page, title in self?.present(page, title: title) }
        tabs.showCover = { [weak self] cover in self?.showCover(cover) }
        tabs.fitWindow = { [weak self] forDesigns in self?.fitWindow(forDesigns: forDesigns) }
        tabs.quit = { [weak self] in self?.quit() }
        // A copy a sync service made of a design is taken back in only when it is not open here.
        WindowsCore.openDesigns = { MainActor.assumeIsolated { Set(Tabs.shared.designs.map { WindowsCore.openKey($0.url) }) } }
        tabs.configure = { view in
            view.session.onOpen = { Tabs.shared.openPanel() }
            view.session.onBringIn = { Tabs.shared.bringInPanel() }
            view.session.onSaveCopy = { [weak view] in
                guard let view else { return }
                let session = view.session
                session.save()
                let copy = WindowsCore.using(session.slot) {
                    try? WindowsCore.saveCopy(named: Words.t("%@ copy", session.name), in: Self.designsFolder)
                }
                guard let copy else { MessageBeep(0); return }
                Tabs.shared.open(copy)
            }
            view.root.requestedTheme = Theme.dark ? .dark : .light
            Tabs.shared.watch(view)
        }
        Bar.chooseDesignsFolder = { [weak self] in self?.chooseDesignsFolder() }
        Bar.bringIn = { Tabs.shared.bringInPanel() }
    }

    @MainActor private func makeHome() -> HomeView {
        let home = HomeView(folder: Self.designsFolder) { url in Tabs.shared.open(url) }
        home.openShareLink = { [weak self] link in self?.openShareLink(link) }
        home.root.requestedTheme = Theme.dark ? .dark : .light
        home.root.loaded.addHandler { _, _ in Trace.time("home on screen") }
        // The tabs' keys on home too: Ctrl+Tab, Ctrl+N, Ctrl+O, Ctrl+W (which quits there).
        home.root.previewKeyDown.addHandler { [weak home] _, args in
            guard let args, !args.handled, home?.menus.isOpen != true else { return }
            _ = Tabs.shared.key(args)
        }
        Tabs.shared.watch(home)
        return home
    }

    /// Puts a tab's page in the window, its bar the window's title bar.
    @MainActor private func present(_ page: TabPage, title: String) {
        guard let window else { return }
        if presented !== page {
            // Only the page, first in the frame, changes: the cover over it goes on as it was.
            if framed {
                frame.children.removeAt(0)
            } else {
                coverLayer.margin = Theme.inset(0, Theme.barHeight, 0, 0)
                frame.children.append(coverLayer)
                window.content = frame
                framed = true
            }
            frame.children.insertAt(0, page.root)
            presented = page
            try? window.setTitleBar(page.dragArea)
        }
        if window.title != title { window.title = title }
    }

    /// Lays a design's opening cover over the page in front, under the bar; nil takes it away.
    @MainActor private func showCover(_ cover: OpeningCover?) {
        guard cover !== shownCover else { return }
        shownCover = cover
        coverLayer.children.clear()
        if let cover { coverLayer.children.append(cover.root) }
    }

    // MARK: The window's size

    /// Home alone keeps the window at its one size, as on the Mac: home's page at its full width
    /// (1320 × 880, no more than the screen less 48), which can't be changed, as more room would
    /// show nothing more. The first design opened makes room for itself: the window grows to all
    /// of the screen the taskbar leaves, but on a very big screen no more than 2560 × 1440, in the
    /// middle, and from then on takes any size. With the last design closed it goes back to home's
    /// size, about its middle.
    @MainActor func fitWindow(forDesigns: Bool, centred: Bool = false) {
        guard let appWindow = window?.appWindow, let presenter,
              let area = try? DisplayArea.getFromWindowId(appWindow.id, .nearest) else { return }
        let hwnd = HWND(bitPattern: UInt(appWindow.id.value))
        let dpi = hwnd.map { GetDpiForWindow($0) } ?? 96
        let scale = Double(dpi == 0 ? 96 : dpi) / 96
        let work = area.workArea
        let b = Self.borders(hwnd)
        // The window as it shows, inside the borders Windows leaves round it to resize it by.
        let shown = (x: Double(appWindow.position.x + b.left), y: Double(appWindow.position.y + b.top),
                     w: Double(appWindow.size.width - b.left - b.right), h: Double(appWindow.size.height - b.top - b.bottom))
        var frame = shown
        if forDesigns {
            presenter.isResizable = true
            presenter.isMaximizable = true
            if presenter.state == .maximized { return }
            let room = (w: min(Double(work.width), 2560 * scale), h: min(Double(work.height), 1440 * scale))
            guard shown.w < room.w - 1 || shown.h < room.h - 1 else { return }
            frame.w = min(max(shown.w, room.w), Double(work.width))
            frame.h = min(max(shown.h, room.h), Double(work.height))
            frame.x = (Double(work.x) + (Double(work.width) - frame.w) / 2).rounded()
            frame.y = (Double(work.y) + (Double(work.height) - frame.h) / 2).rounded()
        } else {
            if presenter.state == .maximized { try? presenter.restore() }
            frame.w = min(1320 * scale, Double(work.width) - 48 * scale).rounded()
            frame.h = min(880 * scale, Double(work.height) - 48 * scale).rounded()
            // In the middle of the screen as Bezzle starts; later it shrinks about its own middle,
            // kept on the screen.
            let middle = centred ? (x: Double(work.x) + Double(work.width) / 2, y: Double(work.y) + Double(work.height) / 2)
                : (x: shown.x + shown.w / 2, y: shown.y + shown.h / 2)
            frame.x = min(max(middle.x - frame.w / 2, Double(work.x)), Double(work.x + work.width) - frame.w).rounded()
            frame.y = min(max(middle.y - frame.h / 2, Double(work.y)), Double(work.y + work.height) - frame.h).rounded()
        }
        try? appWindow.moveAndResize(RectInt32(x: Int32(frame.x) - b.left, y: Int32(frame.y) - b.top,
                                               width: Int32(frame.w) + b.left + b.right, height: Int32(frame.h) + b.top + b.bottom))
        if !forDesigns {
            presenter.isResizable = false
            presenter.isMaximizable = false
        }
    }

    private typealias DwmGetWindowAttribute = @convention(c) (HWND?, DWORD, UnsafeMutableRawPointer?, DWORD) -> HRESULT

    /// The borders Windows leaves round a window, out of sight, for resizing it: between where it
    /// is and where it shows (DWM's extended frame bounds).
    private static func borders(_ hwnd: HWND?) -> (left: Int32, top: Int32, right: Int32, bottom: Int32) {
        var outer = RECT()
        guard let hwnd, GetWindowRect(hwnd, &outer),
              let dll = "dwmapi.dll".withCString(encodedAs: UTF16.self, LoadLibraryW),
              let function = GetProcAddress(dll, "DwmGetWindowAttribute") else { return (0, 0, 0, 0) }
        var frame = RECT()
        // DWMWA_EXTENDED_FRAME_BOUNDS
        let result = unsafeBitCast(function, to: DwmGetWindowAttribute.self)(hwnd, 9, &frame, DWORD(MemoryLayout<RECT>.size))
        guard result >= 0, frame.right > frame.left else { return (0, 0, 0, 0) }
        return (max(0, frame.left - outer.left), max(0, frame.top - outer.top), max(0, outer.right - frame.right), max(0, outer.bottom - frame.bottom))
    }

    // MARK: Quitting

    /// Home is closed: Bezzle quits once every open design is on disk. One that could not be
    /// written keeps it open, unless told to go all the same (the Mac's applicationShouldTerminate).
    @MainActor private func quit() {
        let unsaved = Tabs.shared.saveAll()
        guard !unsaved.isEmpty, let root = presented?.root.xamlRoot else { finishQuitting(); return }
        let dialog = ContentDialog()
        dialog.xamlRoot = root
        if unsaved.count == 1, let design = unsaved.first {
            dialog.title = Words.t("“%@” could not be saved.", design.name)
            dialog.content = design.reason
        } else {
            dialog.title = Words.t("%lld designs could not be saved.", unsaved.count)
            dialog.content = unsaved.map { "\($0.name): \($0.reason)" }.joined(separator: "\n")
        }
        dialog.primaryButtonText = Words.t("Keep Bezzle Open")
        dialog.secondaryButtonText = Words.t("Quit Anyway")
        dialog.secondaryButtonClick.addHandler { [weak self] _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.finishQuitting() } }
        }
        _ = try? dialog.showAsync()
    }

    /// Every tab closed, each design saved and let go, and Bezzle goes. Its window is not taken
    /// down piece by piece first: WinUI fails fast doing that as the app ends (0xe0464645 in
    /// Microsoft.UI.Windowing.dll, seen on closing the window to quit), and nothing is left to keep.
    @MainActor private func finishQuitting() {
        home?.previews.quit()
        Tabs.shared.closeAll()
        MCPServer.shared.stop()
        WebBrowser.shared.quitting()
        Updates.stop()
        // A subject matte cut short by quitting is no matte that took Bezzle down.
        SubjectModel.shared.quitting()
        quitting = true
        Trace.say("quitting, everything saved")
        try? window?.appWindow?.hide()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            _ = TerminateProcess(GetCurrentProcess(), 0)
        }
    }

    // MARK: The AI server

    /// The AI server (Model Context Protocol) at 127.0.0.1:7412, as on the Mac: what it asks of
    /// the window, and it started. BEZZLE_NO_MCP leaves it off, for a copy beside the one in use.
    /// What it asks about one design is about the design the core works on at that moment
    /// (`Tabs.activeTab`): the tab in front, or the one a tool works on.
    @MainActor private func startAIServer() {
        // What it says it is when an assistant connects: Bezzle's version, the Mac's (AppVersion).
        MCPServer.shared.version = AppVersion.short
        guard ProcessInfo.processInfo.environment["BEZZLE_NO_MCP"] == nil else { return }
        let host = MCPHost.shared
        let tabs = Tabs.shared
        var view: DesignWindow? { tabs.activeTab?.view }
        host.designsFolder = { Self.designsFolder }
        host.open = { url in
            tabs.open(url)
            return tabs.tab(showing: url)?.slot != nil
        }
        host.designs = { tabs.byRecency.compactMap(\.slot) }
        host.bringForward = { slot in if let tab = tabs.tab(of: slot) { tabs.select(tab) } }
        host.close = { slot in if let tab = tabs.tab(of: slot) { tabs.close(tab) } }
        host.renamed = { tabs.changed() }
        host.settle = { tabs.activateFront() }
        host.selection = { view?.session.selection ?? [] }
        host.select = { ids in
            guard let session = view?.session else { return }
            session.select(ids, on: ids.first.flatMap(WindowsCore.board(of:)) ?? session.board)
        }
        host.edited = { view?.session.edited(board: nil) }
        host.visible = { view?.canvas.visibleRect ?? .zero }
        host.zoom = { view?.session.zoom ?? 1 }
        host.zoomToFit = { view?.canvas.fit() }
        host.show = { r in view?.canvas.show(r) }
        host.setZoom = { z in view?.canvas.zoom(to: z) }
        host.focusedBoard = { view?.session.board }
        host.endEditing = { view?.canvas.finishTyping() }
        host.broughtIn = { report in view?.showImportReport(report) }
        host.film = { view?.session.film }
        host.mode = { view?.session.mode ?? 0 }
        host.setMode = { mode in view?.session.mode = mode }
        MCPServer.shared.failed = { why in Trace.say("AI server: \(why)") }
        if AIControl.allowed { MCPServer.shared.start() }
        Trace.time("AI server at \(MCPServer.shared.address)")
    }

    @MainActor private func message(_ title: String, detail: String) -> UIElement {
        let stack = StackPanel()
        stack.spacing = 8
        stack.horizontalAlignment = .center
        stack.verticalAlignment = .center
        stack.children.append(Theme.text(title, size: 28, serif: true))
        let body = Theme.text(detail, size: 13, ink: 3)
        body.textWrapping = .wrap
        body.maxWidth = 640
        stack.children.append(body)
        return stack
    }
}
