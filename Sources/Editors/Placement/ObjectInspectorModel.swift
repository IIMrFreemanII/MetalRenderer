import Combine
import Foundation
import MetalRenderer
import Procedural

/// What the Object inspector needs of the renderer (RendererController; a stand-in in the tests).
protocol ObjectInspectorHost: AnyObject {
    var placed: PlacedStatus? { get }
    func observeTick(_ observer: @escaping () -> Void)
    func setPlacedAsset(_ index: Int, of kind: SceneKind, to asset: String)
}

extension RendererController: ObjectInspectorHost {
    var placed: PlacedStatus? { status?.placed }
}

/// The Object inspector's state, on the main thread: the selected object of the scene's file as the renderer reports
/// it, and for a procedural asset (`proc:<slug>?name=value…`) the parameters its network promotes, each with this
/// copy's value or the asset's default.
///
/// A value set is written into the object's asset string (Renderer.setPlacedAsset, through editPlaced): the scene's
/// file is saved and the scene made again with the asset cooked with it. Until the renderer reports the new string
/// back, the inspector shows what was sent.
final class ObjectInspectorModel: ObservableObject {
    /// A promoted parameter as this copy has it.
    struct Row: Identifiable, Equatable {
        let param: PromotedParam
        let value: ProcParam
        /// This copy sets it (else the asset's default).
        let overridden: Bool
        var id: String { param.name }
    }

    let host: ObjectInspectorHost
    private let folder: URL?

    @Published private(set) var placed: PlacedStatus?
    /// The asset a `proc:` object places, read from the library, and the reference with this copy's values.
    @Published private(set) var asset: ProcAsset?
    @Published private(set) var reference: ProcAssetReference?
    /// Why a `proc:` object's asset isn't shown (not in the library).
    @Published private(set) var message: String?

    /// An edit sent that the renderer hasn't reported back yet.
    private var sent: (kind: SceneKind, index: Int, asset: String)?
    /// The asset file read last, and when it was last changed (a save in the Modeller reads it again).
    private var loaded: (slug: String, date: Date?)?
    /// Called when another object is selected (the panel shows itself for a procedural asset's).
    var onSelect: ((PlacedStatus) -> Void)?

    init(host: ObjectInspectorHost, folder: URL? = ProcStore.folder) {
        self.host = host
        self.folder = folder
        host.observeTick { [weak self] in self?.refresh() }
        refresh()
    }

    var rows: [Row] {
        guard let asset, let reference else { return [] }
        let set = asset.values(reference.values)
        return asset.graph.interface.map { p in Row(param: p, value: set[p.name] ?? p.value, overridden: set[p.name] != nil) }
    }

    var isProcedural: Bool { placed?.object.asset.hasPrefix("proc:") == true }

    /// Takes the renderer's report (its stats tick).
    func refresh() {
        var p = host.placed
        if let s = sent {
            if var q = p, q.kind == s.kind, q.index == s.index {
                if q.object.asset == s.asset { sent = nil } else { q.object.asset = s.asset; p = q }
            } else {
                sent = nil
            }
        }
        let date = loaded.flatMap { modified($0.slug) }
        guard p != placed || date != loaded?.date else { return }
        let another = p.map { $0.kind != placed?.kind || $0.index != placed?.index } ?? false
        placed = p
        read()
        if another, let p { onSelect?(p) }
    }

    /// Sets parameter `name` of this copy.
    func set(_ name: String, _ value: ProcParam) {
        guard var r = reference else { return }
        r.values[name] = ProcAssetReference.text(value)
        send(r)
    }

    /// Gives parameter `name` back the asset's default.
    func revert(_ name: String) {
        guard var r = reference, r.values[name] != nil else { return }
        r.values.removeValue(forKey: name)
        send(r)
    }

    /// Every parameter back to the asset's defaults.
    func revertAll() {
        guard var r = reference, !r.values.isEmpty else { return }
        r.values = [:]
        send(r)
    }

    private func send(_ r: ProcAssetReference) {
        guard var p = placed, r.asset != p.object.asset else { return }
        p.object.asset = r.asset
        sent = (p.kind, p.index, r.asset)
        placed = p
        reference = r
        host.setPlacedAsset(p.index, of: p.kind, to: r.asset)
    }

    private func read() {
        guard let p = placed, p.object.asset.hasPrefix("proc:") else {
            (asset, reference, message, loaded) = (nil, nil, nil, nil)
            return
        }
        let r = ProcAssetReference(String(p.object.asset.dropFirst(5)))
        reference = r
        if loaded?.slug != r.slug || modified(r.slug) != loaded?.date || asset == nil {
            asset = ProcStore.read(r.slug, in: folder)
            loaded = (r.slug, modified(r.slug))
        }
        message = asset == nil ? "No procedural asset \(r.slug) in the library" : nil
    }

    private func modified(_ slug: String) -> Date? {
        guard let url = ProcStore.url(slug, in: folder) else { return nil }
        return (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}
