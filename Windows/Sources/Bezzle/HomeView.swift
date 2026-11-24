import Foundation
import WinUI
import UWP
import WinSDK
import BezzleCore

/// Home, as the Mac's (Views/HomeView.swift, HomeStage.swift; numbers in DESIGN.md): the bar
/// with the home tab, Search and Open…; the greeting; the stage with the families of sizes, a
/// click on one making a new design of it; and the designs in the Designs folder.
///
/// For now the sizes stand as sheets of their proportions; the Mac draws each as its device
/// (HomeStage.swift's SizeForm), which is to come.
@MainActor
final class HomeView {
    let root = Grid()
    let dragArea = Border()
    /// Where the tabs go while home is in front (`TabStrip`), and what is beside them at the right.
    let tabsHolder = Border()
    let right = StackPanel()
    /// Bezzle's own menus, over the home screen: a design's menu.
    let menus = MenuHost()
    /// What home asks, as the Mac asks with an alert (ShareViews.swift).
    let questions = Questions()
    /// A design's link pasted or dropped here opens it (Links.swift).
    var openShareLink: ((String) -> Void)?
    /// What home's search looks for among the designs' names.
    private var query = ""
    let previews = HomePreviews()
    private let folder: URL
    private let open: (URL) -> Void
    private let page = StackPanel()
    private let stage = Border()
    private let lineup = StackPanel()
    private let tabs = StackPanel()
    private let designs = StackPanel()
    private var family = 0
    private let sizes = WindowsCore.sizes().flatMap { $0.families }
    private var pixelScale = 1.0

    init(folder: URL, open: @escaping (URL) -> Void) {
        self.folder = folder
        self.open = open
        root.background = Theme.brush(Theme.paper)
        let barRow = RowDefinition()
        barRow.height = GridLength(value: Theme.barHeight, gridUnitType: .pixel)
        let pageRow = RowDefinition()
        pageRow.height = GridLength(value: 1, gridUnitType: .star)
        root.rowDefinitions.append(barRow)
        root.rowDefinitions.append(pageRow)
        root.children.append(bar())

        page.maxWidth = 1240
        page.margin = Theme.inset(40, 14, 40, 56)
        page.spacing = 26
        page.children.append(greeting())
        page.children.append(stageView())
        page.children.append(designsHeading())
        page.children.append(designs)
        let scroll = ScrollView()
        scroll.content = page
        try? Grid.setRow(scroll, 1)
        root.children.append(scroll)
        root.loaded.addHandler { [weak self] _, _ in
            guard let self else { return }
            let scale = self.root.xamlRoot?.rasterizationScale ?? 1
            if self.pixelScale != scale { self.shownWidth = 0 }
            self.pixelScale = scale
            self.showDesigns()
            self.previews.resume()
        }
        root.unloaded.addHandler { [weak self] _, _ in self?.previews.pause() }
        root.sizeChanged.addHandler { [weak self] _, _ in self?.showDesigns() }
        try? Grid.setRowSpan(menus.layer, 2)
        root.children.append(menus.layer)
        try? Grid.setRowSpan(questions.layer, 2)
        root.children.append(questions.layer)
        root.keyDown.addHandler { [weak self] _, args in
            guard let self, let args, !args.handled, !self.questions.key(args) else { return }
            self.pasteLink(args)
        }
        takeDrops()
        // Ctrl+Alt+Shift+I brings a web page in, as ⌥⇧⌘I does on the Mac.
        root.keyDown.addHandler { _, args in
            guard let args, !args.handled, !WebImporting.shared.showing, WebImporting.isShortcut(args.key) else { return }
            args.handled = true
            WebImporting.shared.present()
        }
    }

    // MARK: Bar

    private func bar() -> UIElement {
        let bar = Grid()
        for width in [GridLength(value: 1, gridUnitType: .auto), GridLength(value: 1, gridUnitType: .star),
                      GridLength(value: 1, gridUnitType: .auto), GridLength(value: Bar.captionRoom, gridUnitType: .pixel)] {
            let column = ColumnDefinition()
            column.width = width
            bar.columnDefinitions.append(column)
        }
        // The tabs, home first, which the window puts here while home is in front.
        tabsHolder.verticalAlignment = .center
        tabsHolder.margin = Theme.inset(16, 0, 14, 0)
        bar.children.append(tabsHolder)

        dragArea.background = Theme.clear
        try? Grid.setColumn(dragArea, 1)
        bar.children.append(dragArea)

        right.orientation = .horizontal
        right.spacing = 10
        right.verticalAlignment = .center
        right.margin = Theme.inset(0, 0, 8, 0)
        let search = Theme.well(radius: 8)
        search.width = 200
        search.height = 28
        let field = TextBox()
        field.placeholderText = Words.t("Search")
        field.fontFamily = Theme.ui
        field.fontSize = 12
        field.background = Theme.clear
        field.borderThickness = Theme.inset(0)
        field.padding = Theme.inset(10, 5, 10, 0)
        field.minHeight = 26
        search.child = field
        // The designs whose names have what is typed in them, as it is typed.
        field.textChanged.addHandler { [weak self] sender, _ in
            guard let self, let text = (sender as? TextBox)?.text else { return }
            // A design's link pasted here opens it.
            if self.tookLink(text, from: sender as? TextBox) { return }
            self.query = text.trimmingCharacters(in: .whitespaces)
            // Once the typing is over: pictures made inside the field's event stay blank.
            DispatchQueue.main.async { MainActor.assumeIsolated { self.refresh() } }
        }
        right.children.append(search)
        // A web page brought in as a design, as the Mac's home has it first.
        let website = Controls.cardButton(Words.t("From a Website…"), glyph: Glyphs.globe(size: 12), height: 28) { WebImporting.shared.present() }
        website.verticalAlignment = .center
        try? ToolTipService.setToolTip(website, Words.t("Bring a web page in as a design  Ctrl+Alt+Shift+I"))
        right.children.append(website)
        // A design here is a folder, which Open… picks: files from other apps come in by their own button.
        let bringIn = Theme.card(radius: 8)
        bringIn.height = 28
        let bringLabel = Theme.text(Words.t("Bring In…"), size: 12, weight: 500)
        bringLabel.margin = Theme.inset(12, 0, 12, 0)
        bringIn.child = bringLabel
        bringIn.tapped.addHandler { [weak self] _, _ in self?.chooseAndBringIn() }
        right.children.append(bringIn)
        let openButton = Theme.card(radius: 8)
        openButton.height = 28
        let label = Theme.text(Words.t("Open…"), size: 12, weight: 500)
        label.margin = Theme.inset(12, 0, 12, 0)
        openButton.child = label
        openButton.tapped.addHandler { [weak self] _, _ in self?.chooseAndOpen() }
        right.children.append(openButton)
        try? Grid.setColumn(right, 2)
        bar.children.append(right)
        return bar
    }

    func chooseAndOpen() {
        if let url = FileDialogs.chooseDesign(startingIn: folder) { open(url) }
    }

    func chooseAndBringIn() {
        if let url = FileDialogs.chooseFileToBringIn() { open(url) }
    }

    // MARK: Files dropped on home

    /// StandardDataFormats.StorageItems, which the bindings leave out: files, as Explorer drags them.
    private static let storageItems = "Shell IDList Array"
    /// StandardDataFormats.WebLink: a link, as a browser drags one.
    private static let webLink = "UniformResourceLocatorW"

    /// Designs and files from other apps dropped anywhere on home open, each in a tab of its own,
    /// as on the Mac.
    private func takeDrops() {
        root.allowDrop = true
        root.dragOver.addHandler { _, args in
            guard let args, let view = args.dataView else { return }
            // Words or a link dragged in, as from a browser or a mail: a design's link, or a page to bring in.
            let link = (try? view.contains(Self.webLink)) == true || (try? view.contains("Text")) == true
            args.acceptedOperation = (try? view.contains(Self.storageItems)) == true || link ? .copy : .none
        }
        root.drop.addHandler { [weak self] _, args in
            guard let args, let view = args.dataView else { return }
            if (try? view.contains(Self.storageItems)) != true {
                let web = (try? view.contains(Self.webLink)) == true, words = (try? view.contains("Text")) == true
                guard web || words else { return }
                let deferral = try? args.getDeferral()
                Task { @MainActor [weak self] in
                    defer { try? deferral?.complete() }
                    var text: String?
                    if web { text = (try? await view.getWebLinkAsync()?.get())??.absoluteUri }
                    if text == nil, words { text = try? await view.getTextAsync()?.get() }
                    self?.dropped(link: text)
                }
                return
            }
            guard (try? view.contains(Self.storageItems)) == true else { return }
            let deferral = try? args.getDeferral()
            Task { @MainActor [weak self] in
                defer { try? deferral?.complete() }
                guard let items = try? await view.getStorageItemsAsync()?.get() else { return }
                var urls: [URL] = []
                for k in 0..<items.size {
                    if let item = (try? items.getAt(k)) ?? nil, !item.path.isEmpty { urls.append(URL(fileURLWithPath: item.path)) }
                }
                let designs = urls.filter { $0.pathExtension.lowercased() == "bezzle" || WindowsCore.imports($0) }
                guard !designs.isEmpty else { return }
                // After the drop is over: a design's tab comes in front of home, which the drop is still on.
                DispatchQueue.main.async { MainActor.assumeIsolated { designs.forEach { self?.open($0) } } }
            }
        }
    }

    // MARK: Greeting and stage

    private func greeting() -> UIElement {
        let line = StackPanel()
        line.orientation = .horizontal
        line.horizontalAlignment = .center
        line.spacing = 10
        let hour = Calendar.current.component(.hour, from: Date())
        let hello = hour >= 5 && hour < 12 ? "Good morning." : hour >= 12 && hour < 18 ? "Good afternoon." : "Good evening."
        line.children.append(Theme.text(Words.t(hello), size: 34, weight: 500, serif: true))
        line.children.append(Theme.text(Words.t("What are you designing today?"), size: 34, weight: 500, ink: 3, serif: true))
        line.margin = Theme.inset(0, 18, 0, 0)
        return line
    }

    /// The stage: the families' tabs, and the sizes of the one chosen standing on it, on the
    /// table lit as the Mac lights it (its Stage and Daylight).
    private let table = Image()
    private var tableSize = (w: 0, h: 0)

    private func stageView() -> UIElement {
        let holder = Grid()
        holder.cornerRadius = Theme.corners(20)
        table.stretch = .fill
        holder.children.append(table)
        stage.cornerRadius = Theme.corners(20)
        stage.padding = Theme.inset(24, 18, 24, 0)
        let inside = StackPanel()
        tabs.orientation = .horizontal
        tabs.spacing = 4
        tabs.horizontalAlignment = .center
        inside.children.append(tabs)
        lineup.orientation = .horizontal
        lineup.spacing = 26
        lineup.horizontalAlignment = .center
        lineup.margin = Theme.inset(30, 34, 30, 26)
        inside.children.append(lineup)
        stage.child = inside
        holder.children.append(stage)
        holder.sizeChanged.addHandler { [weak self] _, _ in self?.lightTable(holder) }
        showFamily()
        return holder
    }

    private func lightTable(_ holder: Grid) {
        let w = Int((holder.actualWidth * pixelScale).rounded()), h = Int((holder.actualHeight * pixelScale).rounded())
        guard w > 0, h > 0, (w, h) != tableSize else { return }
        tableSize = (w, h)
        let bitmap = WriteableBitmap(Int32(w), Int32(h))
        if let pixels = (try? bitmap.pixelBuffer.buffer).flatMap({ $0 }) {
            _ = WindowsCore.stage(width: w, height: h, scale: pixelScale, table: Theme.table, dark: Theme.dark, into: UnsafeMutableRawPointer(pixels))
        }
        try? bitmap.invalidate()
        table.source = bitmap
    }

    /// How tall the tallest thing stands, and how wide the widest may (the Mac's Lineup).
    private static let tallest = 150.0
    private static let widest = 300.0

    private func showFamily() {
        tabs.children.clear()
        var kindBefore: String?
        for (k, f) in sizes.enumerated() {
            // A hairline between the kinds: devices, social media, print and slides.
            let kind = kinds[k]
            if let before = kindBefore, before != kind {
                let line = Border()
                line.width = 1
                line.height = 16
                line.background = Theme.hairline
                line.margin = Theme.inset(6, 0, 6, 0)
                tabs.children.append(line)
            }
            kindBefore = kind
            let tab = Border()
            tab.height = 28
            tab.cornerRadius = Theme.corners(14)
            let on = k == family
            tab.background = on ? Theme.brush(Theme.card) : Theme.clear
            tab.borderBrush = on ? Theme.hairline : Theme.clear
            tab.borderThickness = Theme.inset(on ? 0.5 : 0)
            let label = Theme.text(Words.t(f.name), size: 12, weight: 500, ink: on ? 1 : 2)
            label.margin = Theme.inset(12, 0, 12, 0)
            tab.child = label
            tab.tapped.addHandler { [weak self] _, _ in self?.family = k; self?.showFamily() }
            tabs.children.append(tab)
        }

        lineup.children.clear()
        let all = sizes[family].sizes
        let forms = all.map { Devices.form(group: $0.group, name: $0.name, width: $0.width, height: $0.height) }
        let drawn = zip(all, forms).map { size, form in (w: size.width * Devices.density(form), h: size.height * Devices.density(form)) }
        // One scale for the whole family, as large as lets its tallest and widest thing fit.
        let first = min(Self.tallest / (drawn.map(\.h).max() ?? 1), Self.widest / (drawn.map(\.w).max() ?? 1))
        var most = (w: 0.0, h: 0.0)
        for (form, d) in zip(forms, drawn) {
            let m = Devices.metrics(form, CGSize(width: d.w * first, height: d.h * first))
            most = (max(most.w, Double(m.size.width)), max(most.h, Double(m.size.height)))
        }
        let scale = first * min(Self.tallest / max(most.h, 1), Self.widest / max(most.w, 1))
        for ((size, form), d) in zip(zip(all, forms), drawn) {
            lineup.children.append(stand(size, form: form, screen: CGSize(width: max((d.w * scale).rounded(), 8), height: max((d.h * scale).rounded(), 8))))
        }
    }

    private lazy var kinds: [String] = WindowsCore.sizes().flatMap { kind in kind.families.map { _ in kind.kind } }

    /// A size standing on the table as the thing it is for, its name and size under it; pointed
    /// at, it lifts, its screen outlined in pencil with a plus on it; a click starts a design.
    private func stand(_ size: WindowsCore.Size, form: Devices.Form, screen: CGSize) -> UIElement {
        let (figure, m) = Devices.view(form, screen: screen)
        let column = StackPanel()
        column.spacing = 14
        let room = Grid()
        room.height = Self.tallest
        room.width = max(Double(m.size.width), 60)
        // Its shadow on the table, and the thing standing on it.
        let shadow = Image()
        shadow.isHitTestVisible = false
        shadow.verticalAlignment = .bottom
        shadow.horizontalAlignment = .center
        let sw = Int((Double(m.size.width) * 0.9 * pixelScale).rounded()), sh = Int((3 * pixelScale).rounded())
        _ = WindowsCore.artboardShadow(width: max(sw, 1), height: max(sh, 1), scale: pixelScale, colour: Theme.shadow) { w, h, pad in
            let bitmap = WriteableBitmap(Int32(w), Int32(h))
            shadow.source = bitmap
            shadow.width = Double(w) / pixelScale
            shadow.height = Double(h) / pixelScale
            shadow.margin = Theme.inset(0, 0, 0, -Double(pad) / pixelScale)
            return (try? bitmap.pixelBuffer.buffer).flatMap { $0.map(UnsafeMutableRawPointer.init) }
        }
        (shadow.source as? WriteableBitmap).map { try? $0.invalidate() }
        room.children.append(shadow)
        let thing = Grid()
        thing.width = Double(m.size.width)
        thing.height = Double(m.size.height)
        thing.verticalAlignment = .bottom
        thing.horizontalAlignment = .center
        // What tips toward the pointer: the thing, its screen's pencil and the plus on it.
        let body = Grid()
        body.width = thing.width
        body.height = thing.height
        thing.children.append(body)
        body.children.append(figure)
        // The pencil round its screen, with a plus, for when it is pointed at.
        let ring = Rectangle()
        ring.width = Double(m.screen.width)
        ring.height = Double(m.screen.height)
        ring.radiusX = m.radius
        ring.radiusY = m.radius
        ring.stroke = Theme.brush(Theme.pencil)
        ring.strokeThickness = 1.5
        ring.horizontalAlignment = .left
        ring.verticalAlignment = .top
        ring.margin = Theme.inset(Double(m.screen.minX), Double(m.screen.minY), 0, 0)
        ring.opacity = 0
        body.children.append(ring)
        let badge = Border()
        badge.width = 22
        badge.height = 22
        badge.cornerRadius = Theme.corners(11)
        badge.background = Theme.brush(Theme.pencil)
        badge.child = Glyphs.view(Glyphs.plus(size: 22), size: 22, brush: Theme.brush(0xFFFFFF))
        badge.horizontalAlignment = .left
        badge.verticalAlignment = .top
        badge.margin = Theme.inset(Double(m.screen.midX) - 11, Double(m.screen.midY) - 11, 0, 0)
        badge.opacity = 0
        let badgeGrow = CompositeTransform()
        badgeGrow.centerX = 11
        badgeGrow.centerY = 11
        badgeGrow.scaleX = 0.2
        badgeGrow.scaleY = 0.2
        badge.renderTransform = badgeGrow
        body.children.append(badge)
        room.children.append(thing)
        column.children.append(room)

        let words = StackPanel()
        words.spacing = 2
        let title = Theme.text(Words.t(size.name), size: 12, weight: 500)
        title.horizontalAlignment = .center
        title.maxWidth = max(room.width + 30, 90)
        let numbers = Theme.text("\(Int(size.width)) × \(Int(size.height))", size: 11, ink: 3)
        numbers.horizontalAlignment = .center
        words.children.append(title)
        words.children.append(numbers)
        column.children.append(words)

        let lift = CompositeTransform()
        thing.renderTransform = lift
        let pick = Pressable(radius: 10) { [weak self] in self?.make(size) }
        pick.hoverWash = 0
        pick.box.child = column
        // Pointed at, it lifts and tips toward the pointer, as the Mac's HomeStage: up 9 points on
        // a spring (response 0.32, damping 0.72), the pencil coming with it; the plus springs up
        // from a fifth of its size (0.3, 0.55) and fades back (ease out, 0.12 s); the tilt
        // follows the pointer (0.28, 0.82), 14 degrees about across and 16 about up at most.
        let motion = StandMotion(slot: CGSize(width: room.width, height: Self.tallest))
        motion.apply = { lifted, plus, tilt in
            lift.translateY = -9 * lifted
            ring.opacity = min(max(lifted, 0), 1)
            badge.opacity = min(max(plus, 0), 1)
            badgeGrow.scaleX = max(0.2 + 0.8 * plus, 0.01)
            badgeGrow.scaleY = max(0.2 + 0.8 * plus, 0.01)
            body.transformMatrix = Motion.turned(CGSize(width: body.width, height: body.height), aboutX: 14 * Double(tilt.y),
                                                 aboutY: 16 * Double(tilt.x), perspective: 0.55)
        }
        pick.box.pointerEntered.addHandler { _, _ in
            motion.point(true)
            title.foreground = Theme.brush(Theme.pencil)
            numbers.foreground = Theme.brush(Theme.pencil, 0.75)
        }
        pick.box.pointerMoved.addHandler { _, args in
            guard let q = try? args?.getCurrentPoint(room)?.position else { return }
            motion.tilt(toward: CGPoint(x: Double(q.x), y: Double(q.y)))
        }
        pick.box.pointerExited.addHandler { _, _ in
            motion.point(false)
            title.foreground = Theme.ink(1)
            numbers.foreground = Theme.ink(3)
        }
        try? ToolTipService.setToolTip(pick.box, Words.t("Start a design %lld by %lld", Int(size.width), Int(size.height)))
        return pick.box
    }

    private func make(_ size: WindowsCore.Size) {
        if let url = try? WindowsCore.createDesign(in: folder, size: size) { open(url) }
    }

    // MARK: Your designs

    private func designsHeading() -> UIElement {
        let heading = Theme.text(Words.t("Your designs"), size: 22, weight: 500, serif: true)
        heading.margin = Theme.inset(0, 12, 0, 0)
        return heading
    }

    private var shownWidth = 0.0

    /// The designs in the Designs folder, newest first, in a grid as wide as the page: tiles at
    /// least 220 wide, 22 apart, thumbnails radius 12 at 480 × 300, names in the serif.
    private func showDesigns() {
        let width = min(1240, max(300, root.actualWidth - 80))
        guard abs(width - shownWidth) > 1 else { return }
        shownWidth = width
        previews.clearCards()
        designs.children.clear()
        designs.spacing = 24
        let urls = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.pathExtension == "bezzle" }
            .filter { query.isEmpty || $0.deletingPathExtension().lastPathComponent.localizedCaseInsensitiveContains(query) }
            .map { (url: $0, version: HomePreviews.version(of: $0)) }
            .sorted { ($0.version ?? .distantPast) > ($1.version ?? .distantPast) }
        let columns = max(1, Int((width + 22) / (220 + 22)))
        let tile = (width - Double(columns - 1) * 22) / Double(columns)
        var row: StackPanel?
        // Designs on their way from a link come first, where they will be (Links.swift).
        let cards = ShareHome.arrivalCards(width: tile) + urls.map { card($0.url, width: tile, version: $0.version) }
        for (k, card) in cards.enumerated() {
            if k % columns == 0 {
                let r = StackPanel()
                r.orientation = .horizontal
                r.spacing = 22
                designs.children.append(r)
                row = r
            }
            row?.children.append(card)
        }
        previews.startNext()
    }

    private func card(_ url: URL, width: Double, version: Date?) -> UIElement {
        let column = StackPanel()
        column.spacing = 10
        column.width = width
        let frame = Border()
        frame.width = width
        frame.height = width * 300 / 480
        frame.cornerRadius = Theme.corners(12)
        frame.background = Theme.brush(Theme.table)
        frame.borderBrush = Theme.hairline
        frame.borderThickness = Theme.inset(0.5)
        let image = Image()
        image.stretch = .uniformToFill
        image.verticalAlignment = .top
        frame.child = image
        previews.show(image, for: url, version: version, width: width, scale: pixelScale)
        column.children.append(frame)
        let name = Theme.text(url.deletingPathExtension().lastPathComponent, size: 15, serif: true)
        column.children.append(name)
        // How it is shared, under its name.
        if let note = ShareHome.note(for: url) { column.children.append(note) }
        let pick = Pressable(radius: 12) { [weak self] in self?.open(url) }
        pick.hoverWash = 0
        // Pointed at, it lifts off the page and tips a little toward the pointer, as a print held
        // up to look at (the Mac's DesignPlate: 5 and 6 degrees at most, on a spring of 0.3, 0.84).
        let lifted = CompositeTransform()
        column.renderTransform = lifted
        let size = CGSize(width: frame.width, height: frame.height)
        let motion = StandMotion(slot: size, tip: Motion.spring(response: 0.3, damping: 0.84))
        motion.apply = { _, _, tilt in
            frame.transformMatrix = Motion.turned(size, aboutX: 5 * Double(tilt.y), aboutY: 6 * Double(tilt.x), perspective: 0.5)
        }
        pick.box.pointerEntered.addHandler { _, _ in
            name.foreground = Theme.brush(Theme.pencil)
            lifted.translateY = -3
            motion.point(true)
        }
        pick.box.pointerMoved.addHandler { _, args in
            guard let q = try? args?.getCurrentPoint(frame)?.position else { return }
            motion.tilt(toward: CGPoint(x: Double(q.x), y: Double(q.y)))
        }
        pick.box.pointerExited.addHandler { _, _ in
            name.foreground = Theme.ink(1)
            lifted.translateY = 0
            motion.point(false)
        }
        pick.box.child = column
        // What a right click on a design offers, as on the Mac.
        let box = pick.box
        box.rightTapped.addHandler { [weak self] _, args in
            args?.handled = true
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.menus.show(below: box, width: 220, entries: self.designEntries(url, rename: { self.rename(url, label: name, column: column) }))
                }
            }
        }
        return box
    }

    private func designEntries(_ url: URL, rename: @escaping @MainActor () -> Void) -> [MenuHost.Entry] {
        [
            .item(Words.t("Open")) { [weak self] in self?.open(url) },
            .item(Words.t("Show in Explorer")) {
                let explorer = Process()
                explorer.executableURL = URL(fileURLWithPath: "C:\\Windows\\explorer.exe")
                explorer.arguments = ["/select," + url.path.replacingOccurrences(of: "/", with: "\\")]
                try? explorer.run()
            },
            // Someone else's design keeps the name it was shared under, as in its tab.
            .item(Words.t("Rename"), enabled: Tabs.shared.mayRename(url) && ShareHome.renamable(url)) { rename() },
            .item(Words.t("Duplicate")) { [weak self] in
                // One open in a tab is copied as it is now.
                Tabs.shared.tab(showing: url)?.save()
                // Named as the Mac's Library.duplicate names it, in the person's language.
                let folder = url.deletingLastPathComponent(), base = Words.t("%@ copy", url.deletingPathExtension().lastPathComponent)
                var copy = folder.appendingPathComponent("\(base).bezzle")
                var i = 2
                while FileManager.default.fileExists(atPath: copy.path) {
                    copy = folder.appendingPathComponent("\(base) \(i).bezzle")
                    i += 1
                }
                guard (try? FileManager.default.copyItem(at: url, to: copy)) != nil else { MessageBeep(0); return }
                // A copy is a design of its own, never shared.
                WindowsCore.forgetSharing(ofCopy: copy, from: url)
                self?.refresh()
            },
            .separator,
            .item(Words.t("Move to Recycle Bin")) { [weak self] in
                guard let self else { return }
                // One this computer shared stops being shared, once the person says so; one open in
                // a tab is closed first, saved, as the Mac's library closes its tab.
                ShareHome.recycle(url, asking: self.questions, closing: {
                    if let tab = Tabs.shared.tab(showing: url) { Tabs.shared.close(tab) }
                }) { [weak self] done in
                    guard done else { MessageBeep(0); return }
                    self?.refresh()
                }
            },
        ]
    }

    /// The design's name typed anew in its place: Enter keeps it, Esc puts it back.
    private func rename(_ url: URL, label: TextBlock, column: StackPanel) {
        var k: UInt32 = 0
        guard (try? column.children.indexOf(label, &k)) == true else { return }
        let field = TextBox()
        field.text = label.text
        field.fontFamily = Theme.serif
        field.fontSize = 15
        field.minHeight = 0
        field.padding = Theme.inset(4, 2, 4, 2)
        column.children.removeAt(k)
        column.children.insertAt(k, field)
        var done = false
        func finish(_ keep: Bool) {
            guard !done else { return }
            done = true
            let typed = field.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let clean = String(typed.map { "\\/:*?\"<>|".contains($0) ? "-" : $0 })
            let target = url.deletingLastPathComponent().appendingPathComponent("\(clean).bezzle")
            // One open in a tab is renamed there, and goes on under its new name, as on the Mac.
            if keep, !clean.isEmpty, clean != label.text, let tab = Tabs.shared.tab(showing: url) {
                if tab.rename(to: clean) {
                    DispatchQueue.main.async { MainActor.assumeIsolated { self.refresh() } }
                    return
                }
            } else if keep, !clean.isEmpty, clean != label.text, !FileManager.default.fileExists(atPath: target.path),
                      (try? FileManager.default.moveItem(at: url, to: target)) != nil {
                DispatchQueue.main.async { MainActor.assumeIsolated { self.refresh() } }
                return
            }
            if keep, !clean.isEmpty, clean != label.text { MessageBeep(0) }
            var at: UInt32 = 0
            if (try? column.children.indexOf(field, &at)) == true {
                column.children.removeAt(at)
                column.children.insertAt(at, label)
            }
        }
        field.keyDown.addHandler { _, args in
            guard let args else { return }
            if args.key == .enter { args.handled = true; finish(true) }
            if args.key == .escape { args.handled = true; finish(false) }
        }
        field.lostFocus.addHandler { _, _ in finish(true) }
        field.loaded.addHandler { sender, _ in
            guard let box = sender as? TextBox else { return }
            _ = try? box.focus(.programmatic)
            try? box.selectAll()
        }
    }

    // MARK: Links pasted or dropped

    /// Ctrl+V with a design's link on the clipboard opens it.
    private func pasteLink(_ args: KeyRoutedEventArgs) {
        guard args.key == .v, GetKeyState(Int32(VK_CONTROL)) < 0, let text = Clipboard.text, WindowsCore.isShareLink(text) else { return }
        args.handled = true
        let link = text
        DispatchQueue.main.async { MainActor.assumeIsolated { self.openShareLink?(link) } }
    }

    /// Whether what the search field holds now is a design's link, which opens instead.
    private func tookLink(_ text: String, from field: TextBox?) -> Bool {
        guard WindowsCore.isShareLink(text) else { return false }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                field?.text = ""
                self.openShareLink?(text)
            }
        }
        return true
    }

    /// Words or a link dropped here: a design's link opens.
    /// A link dropped on home: a design's link opens the design; another web page's address is a
    /// page to bring in, as on the Mac.
    private func dropped(link text: String?) {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return }
        // After the drop is over: opening replaces home, which the drop is still on.
        if WindowsCore.isShareLink(text) {
            DispatchQueue.main.async { MainActor.assumeIsolated { self.openShareLink?(text) } }
        } else if ["http://", "https://"].contains(where: { text.lowercased().hasPrefix($0) }) {
            DispatchQueue.main.async { MainActor.assumeIsolated { WebImporting.shared.present(text) } }
        }
    }

    /// The designs listed again, as they are in the folder now.
    func refresh() {
        shownWidth = 0
        showDesigns()
    }
}

/// How a size on home's stage moves while it is pointed at (the Mac's HomeStage): lifted, its
/// plus shown, and tipped toward the pointer, each on the Mac's spring for it.
@MainActor
private final class StandMotion {
    /// What is drawn from the motion: how far lifted and how far the plus has come, 0 to 1, and
    /// the tilt, each way from -0.5 to 0.5.
    var apply: (Double, Double, CGPoint) -> Void = { _, _, _ in }
    private let slot: CGSize
    private var lifted = DeckSpring(0)
    private var plus = DeckSpring(0)
    private var plusOut: (from: Double, elapsed: Double)?
    private var tiltX = DeckSpring(0)
    private var tiltY = DeckSpring(0)
    private lazy var ticker = Motion.Ticker { [weak self] dt in self?.step(dt) ?? false }

    private static let lift = Motion.spring(response: 0.32, damping: 0.72)
    private static let pop = Motion.spring(response: 0.3, damping: 0.55)
    private let tip: (stiffness: Double, damping: Double)

    /// The tilt on the Mac's interactive spring for it: a size's (0.28, 0.82) unless said.
    init(slot: CGSize, tip: (stiffness: Double, damping: Double) = Motion.spring(response: 0.28, damping: 0.82)) {
        self.slot = slot
        self.tip = tip
    }

    func point(_ on: Bool) {
        lifted.target = on ? 1 : 0
        if on {
            plusOut = nil
            plus.target = 1
        } else {
            plusOut = (min(max(plus.value, 0), 1), 0)
            tiltX.target = 0
            tiltY.target = 0
        }
        ticker.start()
    }

    /// The pointer at `p` in the size's place on the stage.
    func tilt(toward p: CGPoint) {
        // Only over the thing itself, as the Mac follows the pointer over it alone.
        let x = Double(p.x) / max(Double(slot.width), 1), y = Double(p.y) / max(Double(slot.height), 1)
        let over = (0...1).contains(x) && (0...1).contains(y)
        tiltX.target = over ? x - 0.5 : 0
        tiltY.target = over ? y - 0.5 : 0
        ticker.start()
    }

    private func step(_ dt: Double) -> Bool {
        lifted.step(dt, stiffness: Self.lift.stiffness, damping: Self.lift.damping)
        if var out = plusOut {
            out.elapsed += dt
            let k = min(out.elapsed / 0.12, 1)
            plus = DeckSpring(out.from * (1 - Motion.easeOut(k)))
            plusOut = k < 1 ? out : nil
        } else {
            plus.step(dt, stiffness: Self.pop.stiffness, damping: Self.pop.damping)
        }
        tiltX.step(dt, stiffness: tip.stiffness, damping: tip.damping)
        tiltY.step(dt, stiffness: tip.stiffness, damping: tip.damping)
        apply(lifted.value, plus.value, CGPoint(x: tiltX.value, y: tiltY.value))
        return !lifted.settled || !plus.settled || plusOut != nil || !tiltX.settled || !tiltY.settled
    }
}
