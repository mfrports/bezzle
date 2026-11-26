import Foundation
import WinSDK
import WinUI
import WinAppSDK
import UWP
import BezzleCore

/// Bezzle's browser in a window of its own, as the Mac's (Import/WebBrowser.swift: its window,
/// WebBrowserBar, PagesButton, PagesList, SizeButton): the page's title and where its pages go
/// over the bar; back, forward and again, the address, the site's pages, the size the page is
/// read at, and Import; under it the page as wide as it is read. The page itself is WebView2's
/// own window, which the core lays over this one where the page goes (`WebBrowser.place(in:)`)
/// and moves with it; while it is away (read at its full size, or under the list of pages, as
/// nothing in this window can lie over it) a picture of it holds its place.
@MainActor
final class BrowserWindow {
    static let shared = BrowserWindow()

    /// The heights of the title over the bar and of the bar, and how narrow the window goes, so
    /// the bar has room: a phone's page lies in the middle of it.
    static let titleHeight = 44.0
    static let barHeight = 52.0
    static let narrowest = 760.0

    private var window: Window?
    private var presenter: OverlappedPresenter?
    private var placedOnce = false
    private var browser: WebBrowser { WebBrowser.shared }

    private let root = Grid()
    private let titleText = Theme.text("", size: 12.5, weight: 600)
    private let subtitleText = Theme.text("", size: 11.5, ink: 3)
    private let titleArea = Border()
    private let page = Grid()
    private let still = Image()
    private var stillBitmap: WriteableBitmap?

    private var back: Pressable?
    private var forward: Pressable?
    private var again: Pressable?
    private let address = TextBox()
    /// The page's address the field last showed.
    private var addressShown: URL?
    private var lock: FrameworkElement?
    private var globe: FrameworkElement?
    private var pagesButton: Pressable?
    private var sizes: [(press: Pressable, glyph: FrameworkElement, width: WindowsCore.WebWidth)] = []
    private let importBack = Border()
    private let importFill = Border()
    private let importLabel = Theme.text("", size: 13, weight: 600)
    private static let importWidth = 132.0

    // The list of pages.
    private let listLayer = Grid()
    private let listCard = Border()
    private let listRows = StackPanel()
    private let listStage = Theme.text("", size: 11.5, ink: 3)
    private var listCancel: UIElement?
    private let listImportBack = Border()
    private let listImportFill = Border()
    private let listImportLabel = Theme.text("", size: 13, weight: 600)
    private static let listImportWidth = 176.0
    private var listOpen = false
    /// What the list shows now, so it is made again only when that changes.
    private var listShown = ""

    private init() {}

    /// What the core asks of the window, given once as Bezzle starts.
    func connect(opened: @escaping @MainActor @Sendable (URL, WindowsCore.ImportSummary?) async -> WindowsCore.Slot?,
                 broughtIn: @escaping (WindowsCore.Slot, [UUID], WindowsCore.ImportSummary) -> Void,
                 designsFolder: @escaping () -> URL) {
        var hooks = WebBrowser.Window()
        hooks.present = { [weak self] activate in self?.present(activate: activate) }
        hooks.dismiss = { [weak self] in self?.dismiss() }
        hooks.changed = { [weak self] in self?.refresh() }
        hooks.layOut = { [weak self] in self?.layOut() }
        hooks.still = { [weak self] still in self?.hold(still) }
        hooks.opened = opened
        hooks.broughtIn = broughtIn
        hooks.designsFolder = designsFolder
        browser.window = hooks
    }

    // MARK: The window

    private var hwnd: HWND? {
        guard let id = window?.appWindow?.id else { return nil }
        return HWND(bitPattern: UInt(id.value))
    }

    /// Device pixels to a point on the screen the window is on.
    private var scale: Double {
        guard let hwnd else { return Double(GetDpiForSystem()) / 96 }
        let dpi = GetDpiForWindow(hwnd)
        return Double(dpi == 0 ? 96 : dpi) / 96
    }

    private func make() -> Window {
        if let window { return window }
        let window = Window()
        window.title = Words.t("Import from a Website")
        window.extendsContentIntoTitleBar = true
        if let appWindow = window.appWindow {
            if let presenter = try? OverlappedPresenter.create() {
                presenter.isResizable = false
                presenter.isMaximizable = false
                try? appWindow.setPresenter(presenter)
                self.presenter = presenter
            }
            if let bar = appWindow.titleBar {
                bar.buttonBackgroundColor = UWP.Color(a: 0, r: 0, g: 0, b: 0)
                bar.buttonInactiveBackgroundColor = UWP.Color(a: 0, r: 0, g: 0, b: 0)
                bar.buttonForegroundColor = Theme.color(Theme.ink)
                bar.buttonInactiveForegroundColor = Theme.color(Theme.ink, 0.44)
                bar.buttonHoverBackgroundColor = Theme.color(Theme.ink, 0.06)
            }
            // Closed by the person, it goes off the screen; its page stays open out of sight.
            appWindow.closing.addHandler { [weak self] _, args in
                args?.cancel = true
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.closedByPerson() } }
            }
            // Moved, the page goes with it.
            appWindow.changed.addHandler { [weak self] _, args in
                guard args?.didPositionChange == true else { return }
                MainActor.assumeIsolated { self?.placePage() }
            }
        }
        build()
        window.content = root
        try? window.setTitleBar(titleArea)
        self.window = window
        return window
    }

    func present(activate: Bool) {
        let window = make()
        layOut()
        if !placedOnce, let appWindow = window.appWindow, let area = try? DisplayArea.getFromWindowId(appWindow.id, .nearest) {
            // In the middle of the screen the first time, as the Mac's is centred.
            let work = area.workArea, size = appWindow.size
            try? appWindow.move(PointInt32(x: work.x + (work.width - size.width) / 2, y: work.y + max(0, (work.height - size.height) / 2)))
            placedOnce = true
        }
        if activate {
            try? window.activate()
        } else {
            try? window.appWindow?.show(false)
        }
        refresh()
        layOut()
    }

    func dismiss() {
        closeList()
        try? window?.appWindow?.hide()
    }

    private func closedByPerson() {
        closeList()
        try? window?.appWindow?.hide()
        browser.windowClosed()
    }

    /// The window fitted to the size the page is read at: as wide, at least as wide as the bar
    /// needs, and as tall as the screen has room for; and the page placed under the bar.
    func layOut() {
        guard let window, let appWindow = window.appWindow else { return }
        let width = browser.width.width
        let room: Double = {
            guard let area = try? DisplayArea.getFromWindowId(appWindow.id, .nearest) else { return 1000 }
            return Double(area.workArea.height) / scale
        }()
        let chrome = Self.titleHeight + Self.barHeight
        let height = min(browser.pageHeight, max(320, room - chrome - 40)).rounded()
        let inside = CGSize(width: max(width, Self.narrowest), height: chrome + height)
        let s = scale
        try? appWindow.resizeClient(SizeInt32(width: Int32((inside.width * s).rounded()), height: Int32((inside.height * s).rounded())))
        page.width = inside.width
        page.height = height
        still.width = width
        still.height = height
        pageSpot = (((inside.width - width) / 2).rounded(), chrome, height)
        placePage()
    }

    /// Where the page goes in the window, as last laid out: its left, its top and its height.
    private var pageSpot: (x: Double, y: Double, height: Double)?

    /// Tells the browser where its page goes now.
    private func placePage() {
        guard let hwnd, let spot = pageSpot else { return }
        browser.place(in: UInt(bitPattern: hwnd), x: spot.x, y: spot.y, height: spot.height, scale: scale)
    }

    /// A picture of the page in its place, or none.
    private func hold(_ picture: WebBrowser.Still?) {
        guard let picture, picture.width > 0, picture.height > 0 else {
            still.source = nil
            stillBitmap = nil
            still.visibility = .collapsed
            return
        }
        var bitmap: WriteableBitmap? = WriteableBitmap(Int32(picture.width), Int32(picture.height))
        if let raw = (try? bitmap?.pixelBuffer.buffer).flatMap({ $0.map(UnsafeMutableRawPointer.init) }) {
            picture.bgra.withUnsafeBytes { bytes in
                guard let from = bytes.baseAddress else { return }
                raw.copyMemory(from: from, byteCount: min(bytes.count, picture.width * picture.height * 4))
            }
        } else {
            bitmap = nil
        }
        try? bitmap?.invalidate()
        stillBitmap = bitmap
        still.source = bitmap
        still.visibility = .visible
    }

    // MARK: Building

    private func build() {
        root.requestedTheme = Theme.dark ? .dark : .light
        root.background = Theme.brush(Theme.paper)
        for h in [Self.titleHeight, Self.barHeight] {
            let row = RowDefinition()
            row.height = GridLength(value: h, gridUnitType: .pixel)
            root.rowDefinitions.append(row)
        }
        let rest = RowDefinition()
        rest.height = GridLength(value: 1, gridUnitType: .star)
        root.rowDefinitions.append(rest)

        // The title, and under it where the pages go, or what went wrong, as the Mac's subtitle.
        let titles = StackPanel()
        titles.spacing = 1
        titles.verticalAlignment = .center
        titles.margin = Theme.inset(16, 0, 150, 0)
        titles.children.append(titleText)
        titles.children.append(subtitleText)
        titleArea.background = Theme.clear
        titleArea.child = titles
        root.children.append(titleArea)

        let bar = makeBar()
        try? Grid.setRow(bar, 1)
        root.children.append(bar)

        page.horizontalAlignment = .left
        page.verticalAlignment = .top
        page.background = Theme.brush(Theme.paper)
        still.stretch = .fill
        still.horizontalAlignment = .center
        still.verticalAlignment = .top
        still.visibility = .collapsed
        still.isHitTestVisible = false
        page.children.append(still)
        try? Grid.setRow(page, 2)
        root.children.append(page)

        buildList()
        try? Grid.setRow(listLayer, 1)
        try? Grid.setRowSpan(listLayer, 2)
        root.children.append(listLayer)
    }

    private func makeBar() -> FrameworkElement {
        let holder = Border()
        holder.background = Theme.brush(Theme.paper)
        holder.borderBrush = Theme.hairline
        holder.borderThickness = Theme.inset(0, 0, 0, 0.5)
        let row = Grid()
        row.margin = Theme.inset(12, 0, 12, 0)
        row.columnSpacing = 4
        for width in [GridLength(value: 1, gridUnitType: .auto), GridLength(value: 1, gridUnitType: .auto), GridLength(value: 1, gridUnitType: .auto),
                      GridLength(value: 1, gridUnitType: .star), GridLength(value: 1, gridUnitType: .auto), GridLength(value: 1, gridUnitType: .auto),
                      GridLength(value: 1, gridUnitType: .auto)] {
            let column = ColumnDefinition()
            column.width = width
            row.columnDefinitions.append(column)
        }
        var column: Int32 = 0
        func add(_ e: FrameworkElement) {
            e.verticalAlignment = .center
            try? Grid.setColumn(e, column)
            row.children.append(e)
            column += 1
        }
        let back = iconButton(Glyphs.back(size: 14), help: "Back") { [weak self] in self?.browser.back() }
        let forward = iconButton(Glyphs.forwardChevron(size: 14), help: "Forward") { [weak self] in self?.browser.forward() }
        let again = iconButton(Glyphs.reload(size: 14), help: "Reload") { [weak self] in self?.browser.reload() }
        self.back = back
        self.forward = forward
        self.again = again
        add(back.box)
        add(forward.box)
        add(again.box)

        // The address, in a well with a lock or the globe before it.
        let well = Theme.well(radius: 7)
        well.height = 30
        well.margin = Theme.inset(6, 0, 0, 0)
        let inside = Grid()
        let first = ColumnDefinition()
        first.width = GridLength(value: 1, gridUnitType: .auto)
        let second = ColumnDefinition()
        second.width = GridLength(value: 1, gridUnitType: .star)
        inside.columnDefinitions.append(first)
        inside.columnDefinitions.append(second)
        let lock = Glyphs.view(Glyphs.lock(locked: true, size: 11), size: 11, brush: Theme.ink(3))
        let globe = Glyphs.view(Glyphs.globe(size: 11), size: 11, brush: Theme.ink(3))
        for g in [lock, globe] {
            g.verticalAlignment = .center
            g.margin = Theme.inset(10, 0, 0, 0)
            inside.children.append(g)
        }
        self.lock = lock
        self.globe = globe
        styleAddress()
        try? Grid.setColumn(address, 1)
        inside.children.append(address)
        well.child = inside
        address.keyDown.addHandler { [weak self] _, args in
            guard let self, let args, args.key == .enter else { return }
            args.handled = true
            self.browser.typed = self.address.text
            self.browser.go(self.address.text)
        }
        address.textChanged.addHandler { [weak self] _, _ in
            guard let self else { return }
            self.browser.typed = self.address.text
        }
        add(well)

        let pages = iconButton(Glyphs.stack(size: 14), help: "Pages") { [weak self] in self?.toggleList() }
        pages.box.margin = Theme.inset(6, 0, 0, 0)
        pages.onLook = { Theme.brush(Theme.pencil, Theme.pencilWash) }
        pagesButton = pages
        add(pages.box)

        let sizes = StackPanel()
        sizes.orientation = .horizontal
        sizes.spacing = 2
        sizes.margin = Theme.inset(8, 0, 8, 0)
        for (glyph, help, width) in [(Glyphs.desktop(size: 14), "Desktop", WindowsCore.WebWidth.desktop), (Glyphs.tablet(size: 14), "Tablet", .tablet),
                                     (Glyphs.phone(size: 14), "Mobile", .mobile)] {
            let picture = Glyphs.view(glyph, size: 14, brush: Theme.ink(2))
            let press = Pressable(radius: 6) { [weak self] in
                guard let self, self.browser.width.width != width.width else { return }
                self.browser.resize(to: width)
            }
            press.box.width = 30
            press.box.height = 28
            press.onLook = { Theme.brush(Theme.pencil, Theme.pencilWash) }
            picture.horizontalAlignment = .center
            picture.verticalAlignment = .center
            press.box.child = picture
            try? ToolTipService.setToolTip(press.box, Words.t(help))
            sizes.children.append(press.box)
            self.sizes.append((press, picture, width))
        }
        add(sizes)
        add(primary(width: Self.importWidth, back: importBack, fill: importFill, label: importLabel) { [weak self] in self?.browser.importFromWindow() })
        holder.child = row
        return holder
    }

    private func iconButton(_ glyph: [Glyphs.Part], help: String, _ action: @escaping @MainActor () -> Void) -> Pressable {
        let press = Pressable(radius: 6, action: action)
        press.box.width = 30
        press.box.height = 28
        let picture = Glyphs.view(glyph, size: 14, brush: Theme.ink(2))
        picture.horizontalAlignment = .center
        picture.verticalAlignment = .center
        press.box.child = picture
        try? ToolTipService.setToolTip(press.box, Words.t(help))
        return press
    }

    /// The address field, as the Mac's plain TextField: no chrome of its own in the well.
    private func styleAddress() {
        address.allowFocusOnInteraction = true
        address.fontFamily = Theme.ui
        address.fontSize = 12.5
        address.minWidth = 0
        address.minHeight = 0
        address.verticalAlignment = .center
        address.borderThickness = Theme.inset(0)
        address.background = Theme.clear
        address.textWrapping = .noWrap
        address.acceptsReturn = false
        address.placeholderText = "example.com"
        address.padding = Theme.inset(7, 5, 10, 0)
        for key in ["TextControlBackground", "TextControlBackgroundPointerOver", "TextControlBackgroundFocused", "TextControlBackgroundDisabled",
                    "TextControlBorderBrush", "TextControlBorderBrushPointerOver", "TextControlBorderBrushFocused", "TextControlBorderBrushDisabled"] {
            _ = address.resources?.insert(key, Theme.clear)
        }
        for key in ["TextControlForeground", "TextControlForegroundPointerOver", "TextControlForegroundFocused", "TextControlForegroundDisabled"] {
            _ = address.resources?.insert(key, Theme.ink(1))
        }
    }

    /// The Mac's PrimaryButton: ink with the paper's colour on it, filling with pencil from the
    /// left as the work goes.
    private func primary(width: Double, back: Border, fill: Border, label: TextBlock, _ action: @escaping @MainActor () -> Void) -> FrameworkElement {
        let press = Pressable(radius: 9, action: action)
        press.hoverWash = 0
        let box = Grid()
        box.width = width
        box.height = 34
        back.cornerRadius = Theme.corners(9)
        box.children.append(back)
        fill.horizontalAlignment = .left
        fill.cornerRadius = Theme.corners(9)
        fill.background = Theme.brush(Theme.pencil)
        box.children.append(fill)
        label.horizontalAlignment = .center
        label.verticalAlignment = .center
        box.children.append(label)
        press.box.child = box
        return press.box
    }

    private func paintPrimary(back: Border, fill: Border, label: TextBlock, title: String, width: Double, enabled: Bool, progress: Double?) {
        back.background = Theme.brush(Theme.ink, enabled || progress != nil ? 1 : 0.22)
        label.text = title
        label.foreground = Theme.brush(Theme.paper, enabled || progress != nil ? 1 : 0.8)
        if let progress {
            fill.visibility = .visible
            fill.width = max(12, width * progress)
        } else {
            fill.visibility = .collapsed
        }
    }

    // MARK: The list of pages

    private func buildList() {
        listLayer.visibility = .collapsed
        listLayer.background = Theme.clear
        listLayer.pointerPressed.addHandler { [weak self] _, args in
            args?.handled = true
            self?.closeList()
        }
        listCard.width = 400
        listCard.horizontalAlignment = .right
        listCard.verticalAlignment = .top
        listCard.margin = Theme.inset(0, Self.barHeight - 6, 12 + Self.importWidth + 4, 0)
        listCard.cornerRadius = Theme.corners(12)
        listCard.background = Theme.brush(Theme.paper)
        listCard.borderBrush = Theme.brush(Theme.ink, 0.14)
        listCard.borderThickness = Theme.inset(0.5)
        listCard.pointerPressed.addHandler { _, args in args?.handled = true }
        let stack = StackPanel()
        stack.spacing = 12
        stack.margin = Theme.inset(14)
        let scroller = ScrollViewer()
        scroller.maxHeight = 440
        scroller.verticalScrollBarVisibility = .auto
        listRows.spacing = 10
        scroller.content = listRows
        stack.children.append(scroller)
        let foot = Grid()
        let words = ColumnDefinition()
        words.width = GridLength(value: 1, gridUnitType: .star)
        let cancel = ColumnDefinition()
        cancel.width = GridLength(value: 1, gridUnitType: .auto)
        let button = ColumnDefinition()
        button.width = GridLength(value: 1, gridUnitType: .auto)
        foot.columnDefinitions.append(words)
        foot.columnDefinitions.append(cancel)
        foot.columnDefinitions.append(button)
        foot.columnSpacing = 10
        listStage.verticalAlignment = .center
        foot.children.append(listStage)
        let stop = ExportSheet.textButton("Cancel") { [weak self] in self?.browser.cancelWork() }
        try? Grid.setColumn(stop as? FrameworkElement, 1)
        foot.children.append(stop)
        listCancel = stop
        let go = primary(width: Self.listImportWidth, back: listImportBack, fill: listImportFill, label: listImportLabel) { [weak self] in
            self?.browser.importChosen()
        }
        try? Grid.setColumn(go, 2)
        foot.children.append(go)
        stack.children.append(foot)
        listCard.child = stack
        listLayer.children.append(listCard)
    }

    private func toggleList() {
        if listOpen { closeList() } else { openList() }
    }

    private func openList() {
        guard browser.url != nil, !listOpen else { return }
        listOpen = true
        listShown = ""
        listLayer.visibility = .visible
        refresh()
        Task {
            // The page away under a picture of it, as nothing in the window can lie over it.
            await browser.cover(true)
            await browser.findPages()
            refresh()
        }
    }

    private func closeList() {
        guard listOpen else { return }
        listOpen = false
        listLayer.visibility = .collapsed
        refresh()
        Task { await browser.cover(false) }
    }

    /// The pages offered, in their groups: the one open, those visited, those it links to.
    private func showPages() {
        let pages = browser.listed
        let key = pages.map { "\($0.id)\(browser.chosen.contains($0.id))\(browser.done.contains($0.id))\(browser.reading == $0.id)" }.joined(separator: "|")
            + "\(browser.importing)"
        guard key != listShown else { return }
        listShown = key
        listRows.children.clear()
        for (title, kind) in [(nil, WebBrowser.Listed.Kind.open), ("Visited", .visited), ("Links", .linked)] as [(String?, WebBrowser.Listed.Kind)] {
            let group = pages.filter { $0.kind == kind }
            guard !group.isEmpty else { continue }
            let section = StackPanel()
            section.spacing = 1
            if let title {
                let head = Grid()
                head.margin = Theme.inset(6, 0, 0, 0)
                let words = Theme.text(Words.t(title), size: 11, weight: 600, ink: 3)
                head.children.append(words)
                let all = group.allSatisfy { browser.chosen.contains($0.id) }
                let toggle = ExportSheet.textButton(all ? "None" : "All") { [weak self] in
                    guard let self, !self.browser.importing else { return }
                    for p in group { if all { self.browser.chosen.remove(p.id) } else { self.browser.chosen.insert(p.id) } }
                    self.refresh()
                }
                if let t = toggle as? FrameworkElement { t.horizontalAlignment = .right }
                head.children.append(toggle)
                section.children.append(head)
            }
            for p in group { section.children.append(row(p)) }
            listRows.children.append(section)
        }
    }

    private func row(_ p: WebBrowser.Listed) -> UIElement {
        let on = browser.chosen.contains(p.id)
        let press = Pressable(radius: 6) { [weak self] in
            guard let self, !self.browser.importing else { return }
            if self.browser.chosen.contains(p.id) { self.browser.chosen.remove(p.id) } else { self.browser.chosen.insert(p.id) }
            self.refresh()
        }
        let grid = Grid()
        grid.margin = Theme.inset(6, 5, 6, 5)
        let mark = ColumnDefinition()
        mark.width = GridLength(value: 16, gridUnitType: .pixel)
        let words = ColumnDefinition()
        words.width = GridLength(value: 1, gridUnitType: .star)
        grid.columnDefinitions.append(mark)
        grid.columnDefinitions.append(words)
        grid.columnSpacing = 9
        let box: FrameworkElement
        if browser.done.contains(p.id) {
            box = Glyphs.view(Glyphs.check(size: 10), size: 10, brush: Theme.brush(Theme.pencil))
        } else if browser.reading == p.id {
            box = Glyphs.view(Glyphs.ring(size: 12), size: 12, brush: Theme.brush(Theme.pencil))
        } else {
            let square = Border()
            square.width = 15
            square.height = 15
            square.cornerRadius = Theme.corners(4)
            square.borderThickness = Theme.inset(1)
            square.background = on ? Theme.ink(1) : Theme.clear
            square.borderBrush = on ? Theme.ink(1) : Theme.ink(3)
            let tick = Glyphs.view(Glyphs.check(size: 10), size: 10, brush: Theme.brush(Theme.onInk))
            tick.horizontalAlignment = .center
            tick.verticalAlignment = .center
            tick.opacity = on ? 1 : 0
            square.child = tick
            box = square
        }
        box.horizontalAlignment = .center
        box.verticalAlignment = .center
        grid.children.append(box)
        let lines = StackPanel()
        lines.spacing = 1
        let name = Theme.text(p.name, size: 12.5, weight: p.kind == .open ? 600 : 400)
        let detail = Theme.text(p.detail, size: 11, ink: 3)
        lines.children.append(name)
        lines.children.append(detail)
        try? Grid.setColumn(lines, 1)
        grid.children.append(lines)
        press.box.child = grid
        return press.box
    }

    // MARK: Showing what is so

    func refresh() {
        guard window != nil else { return }
        let b = browser
        let title = b.title.isEmpty ? (b.url?.host ?? Words.t("Import from a Website")) : b.title
        titleText.text = title
        window?.title = title
        if let failure = b.failure {
            subtitleText.text = failure
            subtitleText.foreground = Theme.brush(Theme.warning)
        } else {
            subtitleText.text = b.destinationName.map { Words.t("Into %@", $0) } ?? Words.t("Into a new design")
            subtitleText.foreground = Theme.ink(3)
        }
        for (press, enabled) in [(back, b.canGoBack), (forward, b.canGoForward), (again, b.url != nil)] {
            guard let press else { continue }
            press.box.opacity = enabled ? 1 : 0.35
            press.box.isHitTestVisible = enabled && !b.importing
        }
        let secure = b.url?.scheme == "https"
        lock?.visibility = secure ? .visible : .collapsed
        globe?.visibility = secure ? .collapsed : .visible
        // What the person types stays theirs while they type it, until the page goes elsewhere.
        if b.url != addressShown || (address.focusState == .unfocused && address.text != b.typed) {
            addressShown = b.url
            if address.text != b.typed { address.text = b.typed }
        }
        address.isEnabled = !b.importing
        pagesButton?.isOn = listOpen
        pagesButton?.box.opacity = b.url == nil ? 0.35 : 1
        if let glyph = pagesButton?.box.child as? FrameworkElement { Glyphs.paint(glyph, listOpen ? Theme.brush(Theme.pencil) : Theme.ink(2)) }
        for (press, glyph, width) in sizes {
            let on = b.width.width == width.width
            press.isOn = on
            Glyphs.paint(glyph, on ? Theme.brush(Theme.pencil) : Theme.ink(2))
            press.box.isHitTestVisible = !b.importing
        }
        let label = b.importing ? Words.t("Importing…") : b.justImported ? Words.t("Imported") : Words.t("Import")
        paintPrimary(back: importBack, fill: importFill, label: importLabel, title: label, width: Self.importWidth, enabled: b.canImport, progress: b.progress)
        if listOpen {
            showPages()
            let count = b.listed.filter { b.chosen.contains($0.id) }.count
            listStage.text = b.importing ? (b.stage ?? "") : ""
            listCancel?.visibility = b.importing ? .visible : .collapsed
            paintPrimary(back: listImportBack, fill: listImportFill, label: listImportLabel, title: Words.t("Import %lld Pages", count),
                         width: Self.listImportWidth, enabled: count > 0 && !b.importing, progress: b.importing ? b.progress : nil)
        }
    }
}

extension Glyphs {
    /// A chevron pointing right, for going forward.
    static func forwardChevron(size s: Double = 9) -> [Part] {
        var p = PathData()
        p.move(s * 0.35, s * 0.2); p.line(s * 0.65, s * 0.5); p.line(s * 0.35, s * 0.8)
        return [Part(data: p.d, mode: .stroke, width: 1.3)]
    }

    /// A ring running round clockwise to an arrow at its top, as the Mac's arrow.clockwise.
    static func reload(size s: Double = 14) -> [Part] {
        var p = PathData()
        let cx = s * 0.5, cy = s * 0.52, r = s * 0.3
        var first = true
        var a = -60.0
        while a <= 250 {
            let x = cx + r * cos(a * .pi / 180), y = cy + r * sin(a * .pi / 180)
            if first { p.move(x, y); first = false } else { p.line(x, y) }
            a += 10
        }
        // The arrow at the ring's start, pointing on round.
        let end = -60.0 * .pi / 180
        let ex = cx + r * cos(end), ey = cy + r * sin(end)
        p.move(ex - s * 0.2, ey - s * 0.04); p.line(ex, ey); p.line(ex - s * 0.04, ey + s * 0.2)
        return [Part(data: p.d, mode: .stroke, width: 1.3)]
    }

    /// A screen on its stand, as the Mac's desktopcomputer.
    static func desktop(size s: Double = 14) -> [Part] {
        var screen = PathData(), stand = PathData()
        screen.rect(s * 0.1, s * 0.16, s * 0.8, s * 0.52, radius: s * 0.07)
        stand.move(s * 0.5, s * 0.68); stand.line(s * 0.5, s * 0.82)
        stand.move(s * 0.32, s * 0.84); stand.line(s * 0.68, s * 0.84)
        return [Part(data: screen.d, mode: .stroke, width: 1.2), Part(data: stand.d, mode: .stroke, width: 1.2)]
    }

    /// A tablet upright, as the Mac's ipad.
    static func tablet(size s: Double = 14) -> [Part] {
        var body = PathData()
        body.rect(s * 0.22, s * 0.1, s * 0.56, s * 0.8, radius: s * 0.09)
        return [Part(data: body.d, mode: .stroke, width: 1.2)]
    }

    /// A phone upright, as the Mac's iphone.
    static func phone(size s: Double = 14) -> [Part] {
        var body = PathData(), bar = PathData()
        body.rect(s * 0.31, s * 0.08, s * 0.38, s * 0.84, radius: s * 0.1)
        bar.move(s * 0.44, s * 0.8); bar.line(s * 0.56, s * 0.8)
        return [Part(data: body.d, mode: .stroke, width: 1.2), Part(data: bar.d, mode: .stroke, width: 1.1)]
    }

    /// A compass, as the Mac's safari: a ring, and a needle across it.
    static func compass(size s: Double = 12) -> [Part] {
        var ring = PathData(), needle = PathData()
        ring.ellipse(s * 0.08, s * 0.08, s * 0.84, s * 0.84)
        needle.move(s * 0.68, s * 0.32); needle.line(s * 0.56, s * 0.56); needle.line(s * 0.32, s * 0.68); needle.line(s * 0.44, s * 0.44); needle.close()
        return [Part(data: ring.d, mode: .stroke, width: 1.1), Part(data: needle.d, mode: .fill)]
    }
}
