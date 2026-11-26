import Foundation
import CoreGraphics

/// One property of a layer as JSON holds it, so it can be kept, compared and sent on its own.
nonisolated enum FieldValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([FieldValue])
    case object([String: FieldValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([FieldValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: FieldValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    init<T: Encodable>(encoding value: T) throws {
        self = try JSONDecoder().decode(FieldValue.self, from: JSONEncoder().encode(value))
    }

    func decoded<T: Decodable>(as type: T.Type) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(self))
    }

    /// The same everywhere, to choose between two values when nothing else tells them apart.
    var canonical: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
}

/// One property of a layer that changes on its own: two people changing different properties of
/// the same layer both keep their change. Every stored property of `Node` but its id and what it
/// holds is one; a test makes sure none is forgotten.
// Unchecked: it holds nothing but closures over key paths, set once and never changed.
nonisolated struct LayerField: @unchecked Sendable {
    let name: String
    let same: (Node, Node) -> Bool
    let copy: (inout Node, Node) -> Void
    let write: (inout Node, FieldValue) throws -> Void
    /// For a property that is a dictionary, such as an artboard's guides: its entries, each shared
    /// and undone on its own as a property is, so two people adding guides to one artboard at once
    /// both keep theirs. Shared, each entry is a field of its own, named `name/key`.
    var entries: Entries?

    struct Entries {
        let keys: (Node) -> Set<String>
        let same: (Node, Node, String) -> Bool
        let copy: (inout Node, Node, String) -> Void
        /// The entry as it is shared; null when there is none.
        let value: (Node, String) -> FieldValue
        /// The property as a design's file has it, made of the entries shared of it, by their
        /// keys: an object of them, unless the property is kept another way. Entries it cannot
        /// place, such as a later Bezzle's, it leaves out.
        var gather: ([String: FieldValue]) -> FieldValue = { $0.isEmpty ? .null : .object($0) }
    }

    init<T: Codable & Equatable>(_ name: String, _ key: WritableKeyPath<Node, T>) {
        self.name = name
        same = { $0[keyPath: key] == $1[keyPath: key] }
        copy = { $0[keyPath: key] = $1[keyPath: key] }
        write = { node, value in node[keyPath: key] = try value.decoded(as: T.self) }
    }

    init<T: Codable & Equatable>(_ name: String, entries key: WritableKeyPath<Node, [String: T]?>) {
        self.init(name, key)
        entries = Entries(
            keys: { Set(($0[keyPath: key] ?? [:]).keys) },
            same: { a, b, k in a[keyPath: key]?[k] == b[keyPath: key]?[k] },
            copy: { node, other, k in
                var all = node[keyPath: key] ?? [:]
                all[k] = other[keyPath: key]?[k]
                node[keyPath: key] = all.isEmpty ? nil : all
            },
            value: { node, k in node[keyPath: key]?[k].flatMap { try? FieldValue(encoding: $0) } ?? .null })
    }

    /// For a property that is a few settings kept together, such as an artboard's film: each
    /// setting is an entry, shared and undone on its own as a dictionary's are, so two people
    /// setting different ones at once both keep theirs. `T` is written as an object of its
    /// settings, each left out when it is not set; with none set, there is no value at all.
    init<T: Codable & Equatable>(_ name: String, settings key: WritableKeyPath<Node, T?>) {
        self.init(name, key)
        func set(_ node: Node) -> [String: FieldValue] {
            guard let value = node[keyPath: key], case .object(let settings)? = try? FieldValue(encoding: value) else { return [:] }
            return settings.filter { $0.value != .null }
        }
        entries = Entries(
            keys: { Set(set($0).keys) },
            same: { a, b, k in a[keyPath: key] == b[keyPath: key] || set(a)[k] == set(b)[k] },
            copy: { node, other, k in
                var all = set(node)
                all[k] = set(other)[k]
                node[keyPath: key] = all.isEmpty ? nil : try? FieldValue.object(all).decoded(as: T.self)
            },
            value: { node, k in set(node)[k] ?? .null })
    }

    /// For a layer's motion: each key of each property is an entry, shared and undone on its own,
    /// so two people setting keys of one property at different moments both keep theirs. An entry
    /// is named by its property and the moment its key is at (`MotionKeyPlace`) and holds the
    /// rest of the key. Put together again, a property can have two keys at what is one moment
    /// to the timeline; `repairMotion` leaves one of them.
    init(_ name: String, keys path: WritableKeyPath<Node, [String: MotionTrack]?>) {
        self.name = name
        same = { $0[keyPath: path] == $1[keyPath: path] }
        copy = { $0[keyPath: path] = $1[keyPath: path] }
        // Property by property: one whose keys cannot be read, as a later Bezzle may write
        // them, is left out, and the others are there.
        write = { node, value in
            guard case .object(let tracks) = value else {
                node[keyPath: path] = try value.decoded(as: [String: MotionTrack]?.self)
                return
            }
            let read = tracks.compactMapValues { try? $0.decoded(as: MotionTrack.self) }
            node[keyPath: path] = read.isEmpty ? nil : read
        }
        // The key at a place, at the moment the place says.
        func key(_ node: Node, at place: MotionKeyPlace) -> MotionKey? {
            guard var found = node[keyPath: path]?[place.property]?.keys.last(where: place.holds) else { return nil }
            found.t = place.time
            return found
        }
        entries = Entries(
            keys: { node in
                var names: Set<String> = []
                for (property, track) in node[keyPath: path] ?? [:] {
                    for k in track.keys { names.insert(MotionKeyPlace(property, k).name) }
                }
                return names
            },
            same: { a, b, name in
                guard let place = MotionKeyPlace(name) else { return true }
                return key(a, at: place) == key(b, at: place)
            },
            copy: { node, other, name in
                guard let place = MotionKeyPlace(name) else { return }
                var tracks = node[keyPath: path] ?? [:]
                var keys = tracks[place.property]?.keys ?? []
                keys.removeAll(where: place.holds)
                if let theirs = key(other, at: place) { keys.append(theirs) }
                // A property with no keys left has no track.
                tracks[place.property] = keys.isEmpty ? nil : MotionTrack(keys)
                node[keyPath: path] = tracks.isEmpty ? nil : tracks
            },
            value: { node, name in MotionKeyPlace(name).flatMap { key(node, at: $0) }?.entry ?? .null },
            gather: { entries in
                var tracks: [String: [(place: MotionKeyPlace, key: FieldValue)]] = [:]
                for (name, value) in entries {
                    guard let place = MotionKeyPlace(name), case .object(var key) = value else { continue }
                    // Its name says when it is and whether Bezzle gave it, whatever the entry holds.
                    key["t"] = .number(place.time)
                    key["given"] = place.given ? .bool(true) : nil
                    tracks[place.property, default: []].append((place, .object(key)))
                }
                guard !tracks.isEmpty else { return .null }
                // In the order of their times, a given key after one set at the same moment: the same on every Mac.
                return .object(tracks.mapValues { keys in
                    .object(["keys": .array(keys.sorted { ($0.place.ms, $0.place.given ? 1 : 0) < ($1.place.ms, $1.place.given ? 1 : 0) }.map(\.key))])
                })
            })
    }

    /// The name an entry is shared under.
    func entryName(_ key: String) -> String { "\(name)/\(key)" }

    static let all: [LayerField] = [
        LayerField("kind", \.kind), LayerField("name", \.name), LayerField("frame", \.frame),
        LayerField("rotation", \.rotation), LayerField("fill", \.fill), LayerField("border", \.border),
        LayerField("shadow", \.shadow),
        LayerField("moreFills", \.moreFills), LayerField("moreBorders", \.moreBorders), LayerField("moreShadows", \.moreShadows),
        LayerField("opacity", \.opacity), LayerField("cornerRadius", \.cornerRadius),
        LayerField("corners", \.corners), LayerField("cornerSmoothing", \.cornerSmoothing), LayerField("cornersNamed", \.cornersNamed),
        LayerField("rising", \.rising),
        LayerField("text", \.text), LayerField("style", \.style), LayerField("spans", \.spans), LayerField("path", \.path),
        LayerField("pathBox", \.pathBox), LayerField("evenOdd", \.evenOdd), LayerField("mask", \.mask), LayerField("clipsToFirst", \.clipsToFirst),
        LayerField("blur", \.blur), LayerField("blend", \.blend), LayerField("screen", \.screen), LayerField("hidden", \.hidden),
        LayerField("locked", \.locked), LayerField("clips", \.clips), LayerField("pinsLayers", \.pinsLayers), LayerField("dark", \.dark), LayerField("slideSize", \.slideSize),
        LayerField("transform3D", \.transform3D), LayerField("keepsDepth", \.keepsDepth),
        LayerField("grid", \.grid),
        LayerField("deck", \.deck), LayerField("post", \.post), LayerField("own", \.own),
        LayerField("layout", \.layout), LayerField("guides", entries: \.guides),
        LayerField("exports", \.exports),
        LayerField("instance", \.instance), LayerField("master", \.master),
        LayerField("curve", \.curve), LayerField("curvePath", \.curvePath),
        LayerField("flow", \.flow), LayerField("starts", \.starts),
        LayerField("motion", keys: \.motion), LayerField("film", settings: \.film),
    ]

    /// Each property of a layer, without what it holds, read all at once.
    static func values(of node: Node) -> [String: FieldValue]? {
        var n = node
        n.children = []
        guard case .object(let read)? = try? FieldValue(encoding: n) else { return nil }
        var values: [String: FieldValue] = [:]
        for field in all { values[field.name] = read[field.name] ?? .null }
        return values
    }

    /// The layer these properties make. Any that cannot be read, such as one from a later Bezzle,
    /// is left as a new layer of its kind has it.
    static func node(_ id: UUID, from values: [String: FieldValue]) -> Node {
        var whole = values
        whole["id"] = .string(id.uuidString)
        whole["children"] = .array([])
        // A property's entries, each shared on its own, made one again.
        for field in all {
            guard let entries = field.entries else { continue }
            let prefix = field.entryName("")
            var found: [String: FieldValue] = [:]
            for (name, value) in values where name.hasPrefix(prefix) && value != .null { found[String(name.dropFirst(prefix.count))] = value }
            whole[field.name] = entries.gather(found)
        }
        if let node = try? FieldValue.object(whole).decoded(as: Node.self) { return node }
        let kind = values["kind"].flatMap { try? $0.decoded(as: Node.Kind.self) } ?? .rectangle
        var node = Node(kind: kind, frame: .zero)
        node.id = id
        for field in all { if let v = whole[field.name] { try? field.write(&node, v) } }
        return node
    }
}

/// Where a key of a layer's motion is shared, among the layer's properties: under its property
/// and the moment it is at in whole milliseconds, as `move/1500`. Keys have nothing else to be
/// told apart by, and two people keying a property at different moments write different entries,
/// so both keys stay. A key Bezzle gave to go with the first one posed (`MotionKey.given`) is
/// `move/0/given`: under a name of its own, it never takes the place of a key somebody set at
/// that moment, as the one who saved later would otherwise have it do.
nonisolated struct MotionKeyPlace: Hashable, Sendable {
    var property: String
    var ms: Int
    var given: Bool

    init(_ property: String, _ key: MotionKey) {
        self.property = property
        ms = MotionTiming.milliseconds(key.t)
        given = key.given == true
    }

    /// Read from an entry's name. Only names written as `name` writes them are places: anything
    /// else, such as a whole property's keys shared as one before each was shared on its own, or
    /// what a later Bezzle may add, is none, and is left alone.
    init?(_ name: String) {
        var parts = name.split(separator: "/", omittingEmptySubsequences: false)
        given = parts.count > 2 && parts.last == "given"
        if given { parts.removeLast() }
        guard parts.count > 1, let last = parts.last, let ms = Int(last), ms >= 0, ms <= MotionTiming.lastMillisecond,
              String(ms) == last else { return nil }
        self.ms = ms
        property = parts.dropLast().joined(separator: "/")
        if property.isEmpty { return nil }
    }

    var name: String { given ? "\(property)/\(ms)/given" : "\(property)/\(ms)" }

    /// The moment, in seconds.
    var time: Double { Double(ms) / 1000 }

    /// Whether a key of the property is the one here.
    func holds(_ key: MotionKey) -> Bool { MotionTiming.milliseconds(key.t) == ms && (key.given == true) == given }
}

nonisolated extension MotionKey {
    /// What its entry holds when it is shared: all of it but its time and whether Bezzle gave it,
    /// which the entry's name says. Null for a key that could not be written to a file either.
    var entry: FieldValue {
        guard v.allSatisfy(\.isFinite) else { return .null }
        var fields: [String: FieldValue] = ["v": .array(v.map { .number($0) })]
        if let ease, let value = try? FieldValue(encoding: ease) { fields["ease"] = value }
        return .object(fields)
    }
}

/// Every layer of a design by its id: what it lies in, and the layer itself without what it holds,
/// its frame on its artboard (or the canvas) however deep in groups it lies. A group's frame
/// follows from what it holds, and fitting it again moves what it holds the other way; kept like
/// this, a layer in a group stays put on its artboard through that, so one person's change to a
/// group never moves a layer someone else put somewhere in it.
nonisolated struct FlatDesign: Equatable, Sendable {
    struct Entry: Equatable, Sendable {
        var parent: UUID?
        var node: Node
    }

    var entries: [UUID: Entry] = [:]
    /// What each artboard and group holds, and the canvas under nil, bottom first.
    var order: [UUID?: [UUID]] = [:]
    /// The design's named looks, by their ids. See `Style`.
    var styles: [UUID: Style] = [:]
    /// The notes in its margins, by their ids. See `MarginNote`.
    var notes: [UUID: MarginNote] = [:]

    init() {}

    init(_ doc: BezzleDocument) {
        // Components lie on the canvas here, after everything on it, each marked as one (`Node.master`).
        add(doc.nodes + doc.masters, in: nil, at: nil)
        styles = doc.stylesByID
        notes = doc.notesByID
    }

    private mutating func add(_ nodes: [Node], in parent: UUID?, at origin: CGPoint?) {
        order[parent] = nodes.map(\.id)
        for node in nodes {
            let n = Self.alone(node, at: origin)
            entries[node.id] = Entry(parent: parent, node: n)
            if !node.children.isEmpty { add(node.children, in: node.id, at: node.isGroup ? n.frame.origin : nil) }
        }
    }

    /// A layer as it is kept here: without what it holds, and placed on its artboard.
    private static func alone(_ node: Node, at origin: CGPoint?) -> Node {
        var n = node
        n.children = []
        if let origin { n.frame.origin = n.frame.origin + origin }
        if n.isGroup, let mask = n.mask { n.mask = mask.map { Self.moved($0, by: n.frame.origin) } }
        return n
    }

    /// What changed from one version of a design to the next, as two small flat designs, the
    /// one as it was and the other as it is: the artboards and loose layers that changed, with all
    /// they hold, and the order of all of them. Taken in one against the other, they do just what
    /// the two whole designs would, for nothing else differs, and what lies on the canvas is known
    /// to lie there without its layer; and `replace` makes the flat design of the one into that of
    /// the other. A large design is changed an artboard at a time, and is not gone through whole for it.
    static func changes(from a: BezzleDocument, to b: BezzleDocument) -> (old: FlatDesign, new: FlatDesign) {
        var was: [UUID: Node] = [:]
        let aTop = a.nodes + a.masters, bTop = b.nodes + b.masters
        for node in aTop { was[node.id] = node }
        let changed = bTop.filter { was[$0.id] != $0 }
        let changedIDs = Set(changed.map(\.id)), there = Set(bTop.map(\.id))
        var old = FlatDesign(), new = FlatDesign()
        old.add(aTop.filter { !there.contains($0.id) || changedIDs.contains($0.id) }, in: nil, at: nil)
        new.add(changed, in: nil, at: nil)
        old.order[nil] = aTop.map(\.id)
        new.order[nil] = bTop.map(\.id)
        // The styles and notes are few, and go whole.
        old.styles = a.stylesByID
        new.styles = b.stylesByID
        old.notes = a.notesByID
        new.notes = b.notesByID
        return (old, new)
    }

    /// Made into the flat design of a design's next version, given what `changes` found between them.
    mutating func replace(_ old: FlatDesign, with new: FlatDesign) {
        for id in old.entries.keys { entries[id] = nil }
        for parent in old.order.keys { order[parent] = nil }
        for (id, entry) in new.entries { entries[id] = entry }
        for (parent, list) in new.order { order[parent] = list }
        styles = new.styles
        notes = new.notes
    }

    /// The design these layers make, its groups fitted around what they hold.
    func document() -> BezzleDocument {
        var doc = BezzleDocument()
        var built = Set<UUID>()
        let top = (order[nil] ?? []).compactMap { build($0, at: nil, &built) }
        doc.nodes = top.filter { $0.master == nil }
        doc.masters = top.filter { $0.master != nil }
        let named = styles.values.sorted { ($0.rank, $0.id.uuidString) < ($1.rank, $1.id.uuidString) }
        doc.styles = named.isEmpty ? nil : named
        let written = notes.values.sorted { ($0.time, $0.id.uuidString) < ($1.time, $1.id.uuidString) }
        doc.notes = written.isEmpty ? nil : written
        doc.repairNotes()
        doc.repairGrids()
        doc.repairDecks()
        doc.repairMasks()
        doc.repairComponents()
        doc.repairStyles()
        doc.repairMotion()
        doc.fitGroups()
        doc.fitCarousels()
        return doc
    }

    private func build(_ id: UUID, at origin: CGPoint?, _ built: inout Set<UUID>) -> Node? {
        guard let entry = entries[id], built.insert(id).inserted else { return nil }
        var n = entry.node
        let board = n.frame.origin
        if let origin { n.frame.origin = n.frame.origin - origin }
        if n.isGroup, let mask = n.mask { n.mask = mask.map { Self.moved($0, by: CGPoint.zero - board) } }
        n.children = (order[id] ?? []).compactMap { build($0, at: n.isGroup ? board : nil, &built) }
        return n
    }

    private static func moved(_ node: Node, by d: CGPoint) -> Node {
        var n = node
        n.frame.origin = n.frame.origin + d
        return n
    }

    private func index(of id: UUID) -> Int {
        guard let entry = entries[id] else { return 0 }
        return order[entry.parent]?.firstIndex(of: id) ?? 0
    }

    private func depth(of id: UUID) -> Int {
        var depth = 0
        var parent = entries[id]?.parent
        while let p = parent, depth < 64 {
            depth += 1
            parent = entries[p]?.parent
        }
        return depth
    }

    /// Takes a layer out of where it lies, and puts it into `parent` just above `below`, or at the bottom.
    /// Whether `id` is `other` or lies somewhere inside it.
    private func isWithin(_ id: UUID, _ other: UUID) -> Bool {
        var at: UUID? = id
        var steps = 0
        while let a = at, steps < 64 {
            if a == other { return true }
            at = entries[a]?.parent
            steps += 1
        }
        return false
    }

    private mutating func move(_ id: UUID, to parent: UUID?, above below: UUID?) {
        if let entry = entries[id] { order[entry.parent]?.removeAll { $0 == id } }
        var list = order[parent] ?? []
        list.removeAll { $0 == id }
        let at = below.flatMap { list.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
        list.insert(id, at: at)
        order[parent] = list
        entries[id]?.parent = parent
    }

    private mutating func remove(_ id: UUID) {
        guard let entry = entries.removeValue(forKey: id) else { return }
        order[entry.parent]?.removeAll { $0 == id }
        for child in order.removeValue(forKey: id) ?? [] { remove(child) }
    }
}

extension FlatDesign {
    /// The changes that lead from `from` to `to`, made to `onto`, which others may have changed
    /// since. A property someone else changed afterwards is left as they made it, and a layer
    /// someone else took away stays away; everything else the change did, it does. With nothing
    /// changed since, this is `to` itself. Undo goes through here, so it only ever takes back
    /// what was done on this Mac.
    static func apply(from: BezzleDocument, to: BezzleDocument, onto: BezzleDocument) -> BezzleDocument {
        if onto == from { return to }
        var result = FlatDesign(onto).applying(from: FlatDesign(from), to: FlatDesign(to)).document()
        result.viewport = onto.viewport
        return result
    }

    func applying(from x: FlatDesign, to y: FlatDesign) -> FlatDesign {
        var out = self
        var toPlace: [UUID] = []
        for (id, ey) in y.entries {
            if let ex = x.entries[id] {
                guard var ec = out.entries[id] else { continue }
                if ex.node != ey.node {
                    for field in LayerField.all where !field.same(ex.node, ey.node) {
                        if let entries = field.entries {
                            // Entry by entry: a guide someone else moved since stays where they put it.
                            for k in entries.keys(ex.node).union(entries.keys(ey.node))
                            where !entries.same(ex.node, ey.node, k) && entries.same(ec.node, ex.node, k) {
                                entries.copy(&ec.node, ey.node, k)
                            }
                        } else if field.same(ec.node, ex.node) {
                            field.copy(&ec.node, ey.node)
                        }
                    }
                    out.entries[id] = ec
                }
                if ex.parent != ey.parent && ec.parent == ex.parent { toPlace.append(id) }
            } else if out.entries[id] == nil {
                out.entries[id] = Entry(parent: ey.parent, node: ey.node)
                toPlace.append(id)
            }
        }
        // Layers moved among the others in the same list, as the longest run left in order tells.
        for (parent, ys) in y.order {
            guard let xs = x.order[parent], xs != ys else { continue }
            var positions: [UUID: Int] = [:]
            for (i, id) in xs.enumerated() { positions[id] = i }
            let common = ys.filter { positions[$0] != nil }
            let kept = longestRise(common.map { positions[$0]! }, less: <)
            for (i, id) in common.enumerated() where !kept.contains(i) && out.entries[id]?.parent == parent {
                toPlace.append(id)
            }
        }
        // Each goes back just above the layer it was above, if that is still there; what holds
        // it goes back before it does.
        for id in toPlace.sorted(by: { (y.depth(of: $0), y.index(of: $0)) < (y.depth(of: $1), y.index(of: $1)) }) {
            guard let ey = y.entries[id] else { continue }
            let parent = ey.parent.flatMap { out.entries[$0] == nil ? nil : $0 }
            // Never into itself, which others moving things meanwhile could otherwise make.
            if let parent, out.isWithin(parent, id) { continue }
            let siblings = y.order[ey.parent] ?? []
            let at = siblings.firstIndex(of: id) ?? 0
            let below = siblings[..<at].last { out.entries[$0]?.parent == parent && out.order[parent]?.contains($0) == true }
            out.move(id, to: parent, above: below)
        }
        for id in x.entries.keys where y.entries[id] == nil { out.remove(id) }
        // Styles as layers are: what someone else changed of one since stays as they made it.
        for (id, sy) in y.styles {
            if let sx = x.styles[id] {
                guard var sc = out.styles[id], sx != sy else { continue }
                if sx.name != sy.name, sc.name == sx.name { sc.name = sy.name }
                if sx.look != sy.look, sc.look == sx.look { sc.look = sy.look }
                if sx.rank != sy.rank, sc.rank == sx.rank { sc.rank = sy.rank }
                if sx.dark != sy.dark, sc.dark == sx.dark { sc.dark = sy.dark }
                if sx.library != sy.library, sc.library == sx.library { sc.library = sy.library }
                out.styles[id] = sc
            } else if out.styles[id] == nil {
                out.styles[id] = sy
            }
        }
        for id in x.styles.keys where y.styles[id] == nil { out.styles[id] = nil }
        // Notes the same way: what someone else changed of one since stays as they made it.
        for (id, ny) in y.notes {
            if let nx = x.notes[id] {
                guard var nc = out.notes[id], nx != ny else { continue }
                if nx.text != ny.text, nc.text == nx.text { nc.text = ny.text }
                if nx.done != ny.done, nc.done == nx.done { nc.done = ny.done }
                if nx.on != ny.on || nx.at != ny.at || nx.area != ny.area, nc.on == nx.on, nc.at == nx.at, nc.area == nx.area {
                    nc.on = ny.on; nc.at = ny.at; nc.area = ny.area; nc.place = ny.place
                }
                out.notes[id] = nc
            } else if out.notes[id] == nil {
                out.notes[id] = ny
            }
        }
        for id in x.notes.keys where y.notes[id] == nil { out.notes[id] = nil }
        return out
    }
}
