import Foundation
import WinUI
import UWP
import WindowsFoundation
import WinSDK
import BezzleCore

// Bezzle's one window and its tabs, as the Mac's (App/Tabs.swift): home, always first, and a tab
// for each open design. Opening or making a design gives it a tab and brings it to the front;
// closing its tab saves it, lets it go and brings home back. The window stays as long as Bezzle
// runs: closing it closes the designs in it, and only closing home as well quits Bezzle.
//
// Each design keeps its own history, selection, panels and canvas: its DesignWindow is kept while
// another tab is in front, so coming back shows it at once, its artboards already drawn. The core
// works on the design in front (`WindowsCore.activate`), and on another only for a moment
// (`WindowsCore.using`).

/// What a tab shows in the window: a design, home, or why a design could not be opened. Each
/// has a bar of its own, where the tabs go while it is in front.
@MainActor protocol TabPage: AnyObject {
    var root: Grid { get }
    var tabsHolder: Border { get }
    var dragArea: Border { get }
    var menus: MenuHost { get }
    /// What the bar has at its right, which the tabs leave room for.
    var barRight: FrameworkElement { get }
}

extension DesignWindow: TabPage {}
extension HomeView: TabPage {
    var barRight: FrameworkElement { right }
}

/// A tab without a design in it: one on its way in from another app, or one that could not be
/// opened, and why (the Mac's DesignTabView without a store).
@MainActor
final class MessagePage: TabPage {
    let root = Grid()
    let tabsHolder = Border()
    let dragArea = Border()
    let menus = MenuHost()
    private let right = StackPanel()
    var barRight: FrameworkElement { right }

    init(title: String, detail: String) {
        root.background = Theme.brush(Theme.paper)
        root.requestedTheme = Theme.dark ? .dark : .light
        let barRow = RowDefinition()
        barRow.height = GridLength(value: Theme.barHeight, gridUnitType: .pixel)
        let pageRow = RowDefinition()
        pageRow.height = GridLength(value: 1, gridUnitType: .star)
        root.rowDefinitions.append(barRow)
        root.rowDefinitions.append(pageRow)
        let bar = Grid()
        for width in [GridLength(value: 1, gridUnitType: .auto), GridLength(value: 1, gridUnitType: .star),
                      GridLength(value: 1, gridUnitType: .auto), GridLength(value: Bar.captionRoom, gridUnitType: .pixel)] {
            let column = ColumnDefinition()
            column.width = width
            bar.columnDefinitions.append(column)
        }
        tabsHolder.verticalAlignment = .center
        tabsHolder.margin = Theme.inset(16, 0, 14, 0)
        bar.children.append(tabsHolder)
        dragArea.background = Theme.clear
        try? Grid.setColumn(dragArea, 1)
        bar.children.append(dragArea)
        try? Grid.setColumn(right, 2)
        bar.children.append(right)
        root.children.append(bar)

        let stack = StackPanel()
        stack.spacing = 10
        stack.horizontalAlignment = .center
        stack.verticalAlignment = .center
        let heading = Theme.text(title, size: 22, weight: 500, serif: true)
        heading.horizontalAlignment = .center
        stack.children.append(heading)
        if !detail.isEmpty {
            let body = Theme.text(detail, size: 12.5, ink: 2)
            body.textWrapping = .wrap
            body.textAlignment = .center
            body.horizontalAlignment = .center
            body.maxWidth = 420
            body.lineHeight = 12.5 * 1.45
            stack.children.append(body)
        }
        try? Grid.setRow(stack, 1)
        root.children.append(stack)
        try? Grid.setRowSpan(menus.layer, 2)
        root.children.append(menus.layer)
    }
}

/// One design's tab: the design, once open, or why it could not be, and what stays with it while
/// another tab is in front (the Mac's DesignTab).
@MainActor
final class DesignTab {
    let id = UUID()
    /// The file asked for; the design's own once it is open.
    private(set) var url: URL
    /// The design, with its canvas and panels, once open.
    private(set) var view: DesignWindow?
    /// What shows instead while it comes in from another app, or when it could not be opened.
    private var message: MessagePage?
    fileprivate var opening: Task<Void, Never>?
    /// Whether its name is being typed anew, in its tab.
    var renaming = false
    /// What the window does when a tab's page changes (a design brought in has arrived).
    fileprivate var pageChanged: () -> Void = {}
    /// The paper over the tab while its design opens, Bezzle's mark pressed into it; nil once the
    /// design shows (OpeningCover.swift).
    fileprivate(set) var cover: OpeningCover?

    init(url: URL) {
        self.url = url
    }

    var slot: WindowsCore.Slot? { view.flatMap { $0.session.slot.isOpen ? $0.session.slot : nil } }
    var page: TabPage { view ?? message ?? Self.blank }
    private static let blank = MessagePage(title: "", detail: "")

    var name: String { view?.session.name ?? url.deletingPathExtension().lastPathComponent }

    /// How the design is shared, for its tab to show.
    var mark: WindowsCore.ShareMark? { slot.flatMap { slot in WindowsCore.using(slot) { WindowsCore.shareMark } } }

    /// Whether it may be given a new name here: not someone else's, shared with this computer.
    var mayRename: Bool { slot.map { slot in WindowsCore.using(slot) { WindowsCore.mayRename } } ?? false }

    func shows(_ url: URL) -> Bool { Self.same(url, slot?.url ?? self.url) }

    /// Whether two addresses are the same design, as Windows tells paths apart: whatever the
    /// letters' case, a package's address with or without a slash at its end.
    static func same(_ a: URL, _ b: URL) -> Bool {
        func key(_ u: URL) -> String { u.standardizedFileURL.path.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/\\")) }
        return key(a) == key(b)
    }

    /// Opens the file. One from Adobe XD, Figma, Sketch or Photoshop is brought in as a new design
    /// in the designs folder, which the tab then shows; the file itself is left as it is.
    fileprivate func load(report: WindowsCore.ImportSummary? = nil) async {
        if WindowsCore.imports(url) {
            let source = url
            message = MessagePage(title: Words.t("Bringing in %@…", source.lastPathComponent), detail: "")
            pageChanged()
            do {
                try await Task.sleep(for: .milliseconds(80))
                try Task.checkCancellation()
                let (made, summary) = try WindowsCore.importDesign(source, into: BezzleApp.designsFolder)
                url = made
                do {
                    install(try WindowsCore.openSlot(made), report: summary)
                } catch {
                    showOpenError(error)
                }
            } catch is CancellationError {
                return
            } catch {
                let why = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                message = MessagePage(title: Words.t("Bezzle could not bring in the file"), detail: "\(source.lastPathComponent): \(why)")
            }
            return
        }
        for attempt in 0..<2 {
            do {
                let prepared = try await WindowsCore.prepareOpen(url)
                try Task.checkCancellation()
                install(try WindowsCore.openSlot(prepared), report: report)
                return
            } catch is WindowsCore.OpeningChanged where attempt == 0 {
                continue
            } catch is CancellationError {
                return
            } catch {
                showOpenError(error)
                return
            }
        }
    }

    private func install(_ slot: WindowsCore.Slot, report: WindowsCore.ImportSummary?) {
        let view = DesignWindow(slot: slot)
        Tabs.shared.configure?(view)
        self.view = view
        message = nil
        if let report { view.showImportReport(report) }
    }

    private func showOpenError(_ error: any Swift.Error) {
        let why = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        message = MessagePage(title: Words.t("This design could not be opened."), detail: "\(url.lastPathComponent): \(why)")
    }

    func waitForOpen() async -> WindowsCore.Slot? {
        await opening?.value
        return slot
    }

    /// Another tab comes to the front.
    fileprivate func leaveFront() {
        renaming = false
        guard let view, let slot, view.session.isFront else { return }
        WindowsCore.using(slot) { view.leaveFront() }
    }

    fileprivate func cameToFront() {
        view?.cameToFront()
    }

    /// Saves the design, what is being typed kept, in front or not; `closing`, the last save.
    func save(closing: Bool = false) {
        guard let view, let slot else { return }
        WindowsCore.using(slot) { view.canvas.finishTyping() }
        view.session.save(closing: closing)
    }

    /// Why its last save did not reach the disk, if it did not.
    var unsaved: String? { view?.session.unsaved }

    /// Gives the design a new name, renaming its package; it goes on there, in its tab.
    @discardableResult
    func rename(to name: String) -> Bool {
        guard let view, let slot else { return false }
        let done = WindowsCore.using(slot) { () -> Bool in
            view.canvas.finishTyping()
            return WindowsCore.renameDesign(to: name)
        }
        if done { Tabs.shared.changed() }
        return done
    }

    /// Lets the design go, saved: each time a design is worked on leaves a version, if it changed.
    fileprivate func close() {
        opening?.cancel()
        opening = nil
        message = nil
        guard let view, let slot else { return }
        // In a synced folder, the version and the picture are the computer's that changed it.
        let writes = WindowsCore.using(slot) { () -> Bool in
            view.leaveFront()
            WindowsCore.versions.leave()
            view.session.save(closing: true)
            let writes = WindowsCore.writesWhenClosed
            if writes { WindowsCore.versions.saved(closing: true) }
            return writes
        }
        // A Mac's Finder shows the design as it was closed (the Mac's DesignTab.close).
        if writes { view.session.makePreview() }
        view.session.closed()
        WindowsCore.closeSlot(slot)
        self.view = nil
    }
}

/// The tabs of Bezzle's one window: which designs are open, in what order, and which is in front.
@MainActor
final class Tabs {
    static let shared = Tabs()

    /// The open designs, in the order of their tabs.
    private(set) var designs: [DesignTab] = []
    /// The tab in front; nil for home.
    private(set) var selectedID: UUID?
    /// The design tabs as they were last in front, the latest first.
    private var recency: [UUID] = []
    let strip = TabStrip()

    /// What the window does for the tabs: show a page in it, home's page, fit its size.
    var present: (TabPage, _ title: String) -> Void = { _, _ in }
    /// Lays the cover of a design on its way over the page in front, under the bar, or takes it away.
    var showCover: (OpeningCover?) -> Void = { _ in }
    var home: () -> HomeView? = { nil }
    var fitWindow: (_ forDesigns: Bool) -> Void = { _ in }
    var quit: () -> Void = {}
    /// What a design window needs of the app: opening, saving a copy, bringing in.
    var configure: ((DesignWindow) -> Void)?

    private init() {
        strip.menus = { [weak self] in self?.frontPage.menus }
    }

    var selected: DesignTab? { selectedID.flatMap { id in designs.first { $0.id == id } } }

    /// The open designs, the one in front first, then as they were last looked at.
    var byRecency: [DesignTab] {
        let open = designs.filter { $0.slot != nil }
        var ordered = recency.compactMap { id in open.first { $0.id == id } }
        ordered += open.filter { tab in !ordered.contains { $0 === tab } }
        return ordered
    }

    func tab(showing url: URL) -> DesignTab? { designs.first { $0.shows(url) } }
    func tab(of slot: WindowsCore.Slot) -> DesignTab? { designs.first { $0.slot === slot } }
    /// The tab of the design the core works on now: the one in front, or one lent for a moment.
    var activeTab: DesignTab? { WindowsCore.active.flatMap(tab(of:)) }

    /// Whether a design may be renamed: one open in a tab says, as it may be someone else's.
    func mayRename(_ url: URL) -> Bool { tab(showing: url)?.mayRename ?? true }

    /// What is in front: the design's page, or home.
    var frontPage: TabPage {
        if let selected { return selected.page }
        return home() ?? DesignTab(url: URL(fileURLWithPath: "/")).page
    }

    // MARK: Opening

    /// Opens a design in a new tab after the others and brings it to the front. One open already
    /// comes to the front instead. A file from Adobe XD, Figma, Sketch or Photoshop is brought in
    /// again each time, as a new design.
    ///
    /// A design of Bezzle's opens under a cover, as on the Mac: its tab shows at once, the
    /// window's paper over it with Bezzle's mark pressed into it while the design is prepared.
    /// The cover lifts once the design has been drawn.
    @discardableResult func open(_ url: URL, report: WindowsCore.ImportSummary? = nil) -> DesignTab {
        let url = url.standardizedFileURL
        if !WindowsCore.imports(url), let tab = tab(showing: url) {
            select(tab)
            return tab
        }
        // The one in front lets go of what it holds while it is still the core's.
        selected?.leaveFront()
        if designs.isEmpty { fitWindow(true) }
        let tab = DesignTab(url: url)
        tab.pageChanged = { [weak self, weak tab] in
            guard let self, let tab else { return }
            // Brought in: the core goes back to the design in front, and the page shows if it is.
            if self.selectedID == tab.id { tab.view?.session.cameToFront() } else { tab.view?.session.wentBack() }
            self.activateFront()
            if self.selectedID == tab.id { self.presentFront() }
            self.changed()
        }
        designs.append(tab)
        Trace.time("opening \(url.lastPathComponent)")
        OpeningCover.watchThread()
        let covered = !WindowsCore.imports(url) && !OpeningCover.off
        if covered {
            tab.cover = OpeningCover(plan: OpeningPlan.Cover(began: WindowsCore.now, growing: false))
        }
        show(tab.id)
        tab.opening = Task { [weak self, weak tab] in
            guard let self, let tab, !Task.isCancelled else { return }
            await tab.cover?.waitUntilShown()
            if covered, OpeningCover.hold > 0 {
                try? await Task.sleep(for: .seconds(OpeningCover.hold))
            }
            guard !Task.isCancelled else { return }
            await tab.load(report: report)
            guard !Task.isCancelled else { return }
            Trace.time("design opened")
            self.opened(tab)
            self.uncoverWhenDrawn(tab)
            tab.opening = nil
        }
        return tab
    }

    /// A design opened under its cover: it comes to the front if its tab is, or else the core goes
    /// back to the design in front.
    private func opened(_ tab: DesignTab) {
        if selectedID == tab.id {
            activateFront()
            presentFront()
            tab.cameToFront()
        } else {
            tab.view?.session.wentBack()
            activateFront()
        }
        changed()
    }

    /// Lifts a tab's cover once its canvas has drawn the design, as the canvas does once it is
    /// laid out, a frame after; or, as one out of sight never is, after a while; or at once when
    /// it could not be opened.
    private func uncoverWhenDrawn(_ tab: DesignTab) {
        guard let view = tab.view else { return uncover(tab) }
        let canvas = view.canvas.root
        var ticking: EventCleanup?
        var loading: EventCleanup?
        let drawn: () -> Void = { [weak self, weak tab] in
            loading?.dispose()
            loading = nil
            ticking = CompositionTarget.rendering.addHandler { _, _ in
                MainActor.assumeIsolated {
                    ticking?.dispose()
                    ticking = nil
                    guard let self, let tab else { return }
                    Trace.time("design drawn")
                    self.uncover(tab)
                }
            }
        }
        if canvas.isLoaded {
            drawn()
        } else {
            loading = canvas.loaded.addHandler { _, _ in MainActor.assumeIsolated { drawn() } }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + OpeningPlan.Cover.patience) { [weak self, weak tab] in
            MainActor.assumeIsolated {
                guard let self, let tab else { return }
                self.uncover(tab)
            }
        }
    }

    /// The design in a tab is ready: its cover lifts, with the mark if it came, and is gone after.
    private func uncover(_ tab: DesignTab) {
        guard let cover = tab.cover, !cover.lifting else { return }
        let now = WindowsCore.now
        let lift = cover.plan.lift(readyAt: now)
        cover.lift(at: lift.at, marked: lift.marked)
        Trace.say("opening cover lifts \(lift.marked ? "with" : "without") the mark, \(Int((lift.at - cover.plan.began) * 1000)) ms after it was asked for")
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, cover.plan.gone(readyAt: now) - now)) { [weak self, weak tab] in
            MainActor.assumeIsolated {
                guard let self, let tab, tab.cover === cover else { return }
                tab.cover = nil
                if self.selectedID == tab.id { self.showCover(nil) }
            }
        }
    }

    /// Asks for designs to open, or for files from other apps to bring in, each in a tab of its
    /// own (Ctrl+O).
    func openPanel() {
        guard let url = FileDialogs.chooseDesign(startingIn: BezzleApp.designsFolder) else { return }
        open(url)
    }

    /// Asks for a file from Adobe XD, Figma, Sketch or Photoshop to bring in (Ctrl+Shift+I).
    func bringInPanel() {
        guard let url = FileDialogs.chooseFileToBringIn() else { return }
        open(url)
    }

    // MARK: In front

    /// Home, where a new design is started.
    func showHome() { select(nil) }

    /// Brings a tab to the front; nil is home.
    func select(_ tab: DesignTab?) {
        guard tab?.id != selectedID else { return }
        show(tab?.id)
    }

    /// The next tab along, or the one before, home included, going round.
    func step(by offset: Int) {
        let order: [UUID?] = [nil] + designs.map(\.id)
        guard let at = order.firstIndex(of: selectedID) else { return }
        show(order[((at + offset) % order.count + order.count) % order.count])
    }

    private func show(_ id: UUID?) {
        Trace.say("tab in front: \(id.flatMap { id in designs.first { $0.id == id }?.name } ?? "home")")
        selected?.leaveFront()
        selectedID = id
        if let id {
            recency.removeAll { $0 == id }
            recency.insert(id, at: 0)
        }
        activateFront()
        presentFront()
        selected?.cameToFront()
        if id == nil { home()?.refresh() }
        changed()
    }

    /// What is in front shown in the window, as Bezzle starts or home is made again.
    func showFront() {
        presentFront()
        if selectedID == nil { home()?.refresh() }
        changed()
    }

    /// The core works on the design in front; with home in front, on the one last looked at, which
    /// an AI assistant works on when it names none, as on the Mac.
    func activateFront() {
        WindowsCore.activate(selected?.slot ?? byRecency.first?.slot)
    }

    /// The page in front in the window, the tabs in its bar.
    fileprivate func presentFront() {
        let page = frontPage
        strip.place(in: page.tabsHolder)
        present(page, selected?.name ?? "Bezzle")
        showCover(selected?.cover)
        measureRoom()
    }

    /// The names, marks and order shown again.
    func changed() {
        strip.update()
        if let selected { present(selected.page, selected.name) }
    }

    // MARK: Closing

    /// Closes a design's tab, saving it. Closing the one in front brings home to the front; with
    /// the last design closed, the window goes back to home's size.
    func close(_ tab: DesignTab) {
        guard let index = designs.firstIndex(where: { $0 === tab }) else { return }
        if selectedID == tab.id { show(nil) }
        tab.close()
        designs.remove(at: index)
        recency.removeAll { $0 == tab.id }
        activateFront()
        if designs.isEmpty { fitWindow(false) }
        changed()
        // Its picture on home is as it was closed.
        if selectedID == nil { home()?.refresh() }
    }

    /// The tab in front, home included, which quits Bezzle (Ctrl+W, the Mac's ⌘W).
    func closeFront() {
        if let tab = selected { close(tab) } else { closeHome() }
    }

    func closeOthers(than tab: DesignTab) {
        for other in designs where other !== tab { close(other) }
        select(tab)
    }

    /// The window's close button, and Close Window (Ctrl+Shift+W): with a design in front, every
    /// design closes, each saved, and home stays. Closing home quits Bezzle, once everything is saved.
    func closeWindow() {
        if selectedID == nil {
            closeHome()
        } else {
            for tab in designs { close(tab) }
        }
    }

    /// Home is closed: Bezzle quits, saving every design still open first.
    func closeHome() { quit() }

    /// Bezzle is quitting: what is being typed is kept, and every design saved. Those whose save
    /// did not reach the disk, and why.
    func saveAll() -> [(name: String, reason: String)] {
        designs.compactMap { tab in
            tab.save(closing: true)
            // A Mac's Finder shows the design as it is now, not as it was a few changes ago; in a
            // synced folder, made by the computer that changed it.
            if let slot = tab.slot, WindowsCore.using(slot, { WindowsCore.writesWhenClosed }) { tab.view?.session.makePreview() }
            return tab.unsaved.map { (tab.name, $0) }
        }
    }

    /// Every tab closed, each saved, as Bezzle quits.
    func closeAll() {
        selected?.leaveFront()
        for tab in designs { tab.close() }
        designs = []
        recency = []
        selectedID = nil
        WindowsCore.activate(nil)
    }

    // MARK: Moving and renaming

    /// Moves a tab to another place along the bar.
    func move(id: UUID, to index: Int) {
        guard let from = designs.firstIndex(where: { $0.id == id }) else { return }
        let to = min(max(index, 0), designs.count - 1)
        if from != to { designs.insert(designs.remove(at: from), at: to) }
        strip.update()
    }

    /// Its name typed anew, in its tab.
    func beginRenaming(_ tab: DesignTab) {
        guard tab.mayRename, !tab.renaming else { return }
        tab.renaming = true
        strip.update()
    }

    /// Typing the name is over: kept, or let be (nil).
    func endRenaming(_ tab: DesignTab, to name: String?) {
        guard tab.renaming else { return }
        tab.renaming = false
        if let name { tab.rename(to: name) }
        strip.update()
        if selectedID == tab.id, let view = tab.view {
            DispatchQueue.main.async { MainActor.assumeIsolated { view.canvas.takeKeys() } }
        }
    }

    /// Each open design's file looked for again where it now is, as when it was renamed or moved
    /// in Explorer meanwhile (the Mac follows its designs as Bezzle comes forward).
    func followFiles() {
        var moved = false
        for tab in designs {
            guard let slot = tab.slot, let before = slot.url else { continue }
            WindowsCore.using(slot) { _ = WindowsCore.followDesign() }
            if slot.url != before { moved = true }
        }
        if moved { changed() }
    }

    // MARK: The room in the bar

    /// How much of the bar the tabs may take: all of it but what is at its right, Windows'
    /// buttons and a little to drag the window by.
    func measureRoom() {
        let page = frontPage
        // The bar is as wide as the page.
        let width = Double(page.root.actualWidth)
        guard width > 0 else { return }
        strip.setRoom(width - 16 - 14 - Double(page.barRight.actualWidth) - 8 - Bar.captionRoom - 48)
    }

    /// Keeps the tabs to the room of a page's bar as the window or its bar changes size.
    func watch(_ page: TabPage) {
        page.root.sizeChanged.addHandler { [weak self, weak page] _, _ in
            guard let self, let page, self.frontPage === page else { return }
            self.measureRoom()
        }
        page.barRight.sizeChanged.addHandler { [weak self, weak page] _, _ in
            guard let self, let page, self.frontPage === page else { return }
            self.measureRoom()
        }
    }

    // MARK: Keys

    /// The tabs' keys, as the Mac's menus have them, with Ctrl for ⌘: Ctrl+Tab and Ctrl+Shift+Tab
    /// (Show Next Tab, Show Previous Tab), Ctrl+N (New…, home), Ctrl+O (Open…), Ctrl+Shift+I
    /// (bring in), Ctrl+W (Close Tab, or on home Close, which quits), Ctrl+Shift+W (Close Window) and
    /// Ctrl+Q (Quit).
    /// True when it was one of them.
    func key(_ args: KeyRoutedEventArgs) -> Bool {
        let ctrl = GetKeyState(Int32(VK_CONTROL)) < 0, shift = GetKeyState(Int32(VK_SHIFT)) < 0, alt = GetKeyState(Int32(VK_MENU)) < 0
        guard ctrl, !alt else { return false }
        let action: (() -> Void)?
        switch args.key {
        case .tab: action = { self.step(by: shift ? -1 : 1) }
        case .n where !shift: action = { self.showHome() }
        case .o where !shift: action = { self.openPanel() }
        case .i where shift: action = { self.bringInPanel() }
        case .w: action = shift ? { self.closeWindow() } : { self.closeFront() }
        // Quit, as ⌘Q: every design saved first (Alt+F4 quits too).
        case .q where !shift: action = { self.quit() }
        default: action = nil
        }
        guard let action else { return false }
        args.handled = true
        // After the key: what is in front changes, the element the key came to with it.
        DispatchQueue.main.async { MainActor.assumeIsolated { action() } }
        return true
    }
}
