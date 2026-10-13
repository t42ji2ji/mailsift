import MailCore
import SwiftUI

/// Senders as a constellation: position = what their mail is about (t-SNE of mean embeddings), size = how much
/// they send. Click a dot or a region label to select, drag to box-select, pinch to zoom.
struct SenderMapView: View {
    @Bindable var model: SendersModel
    let map: SenderMap

    @State private var hovered: SenderMap.Point?
    @State private var hoverLocation: CGPoint = .zero
    @State private var box: CGRect?
    @State private var zoom: CGFloat = 1
    @State private var pinch: CGFloat = 1
    @State private var anchor: CGPoint = .init(x: 0.5, y: 0.5)

    private var points: [SenderMap.Point] {
        guard let account = model.account else { return map.points }
        return map.points.filter { $0.stat.account == account }
    }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let scale = zoom * pinch
            ZStack(alignment: .topLeading) {
                Canvas { ctx, _ in
                    let anySelected = !model.selection.isEmpty
                    for p in points {
                        let c = position(p, size, scale)
                        let r = radius(p)
                        let rect = CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
                        let selected = model.selection.contains(p.id)
                        let opacity = selected ? 0.95 : (anySelected ? 0.12 : 0.32)
                        ctx.fill(Path(ellipseIn: rect), with: .color(Theme.ink.opacity(opacity)))
                        if selected || hovered?.id == p.id {
                            ctx.stroke(Path(ellipseIn: rect.insetBy(dx: -3, dy: -3)), with: .color(Theme.ink.opacity(0.8)), lineWidth: 1)
                        }
                    }
                    if let box {
                        ctx.fill(Path(box), with: .color(Theme.ink.opacity(0.05)))
                        ctx.stroke(Path(box), with: .color(Theme.ink.opacity(0.5)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    }
                }
                ForEach(map.clusters) { cluster in
                    ClusterLabel(cluster: cluster, selected: clusterSelected(cluster)) { toggle(cluster) }
                        .position(position(x: cluster.x, y: cluster.y, size, scale))
                }
                if let hovered, box == nil {
                    SenderCard(stat: hovered.stat)
                        .offset(x: min(hoverLocation.x + 14, size.width - 250), y: min(hoverLocation.y + 14, size.height - 90))
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    hoverLocation = location
                    hovered = nearest(location, size, scale)
                case .ended:
                    hovered = nil
                }
            }
            .gesture(select(size, scale))
            .simultaneousGesture(MagnifyGesture()
                .onChanged { value in
                    anchor = CGPoint(x: value.startAnchor.x, y: value.startAnchor.y)
                    pinch = value.magnification
                }
                .onEnded { _ in
                    zoom = min(max(zoom * pinch, 1), 8)
                    pinch = 1
                })
            .overlay(alignment: .topTrailing) {
                if zoom > 1 {
                    IconButton(symbol: "arrow.down.right.and.arrow.up.left", help: "重設縮放") {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            zoom = 1
                            anchor = .init(x: 0.5, y: 0.5)
                        }
                    }
                    .padding(12)
                }
            }
            .clipped()
        }
    }

    // MARK: - Geometry

    private func position(x: Double, y: Double, _ size: CGSize, _ scale: CGFloat) -> CGPoint {
        let side = min(size.width, size.height * 1.4)
        let base = CGPoint(x: (size.width - side) / 2 + x * side, y: (size.height - side / 1.4) / 2 + y * side / 1.4)
        let a = CGPoint(x: anchor.x * size.width, y: anchor.y * size.height)
        return CGPoint(x: a.x + (base.x - a.x) * scale, y: a.y + (base.y - a.y) * scale)
    }

    private func position(_ p: SenderMap.Point, _ size: CGSize, _ scale: CGFloat) -> CGPoint {
        position(x: p.x, y: p.y, size, scale)
    }

    private func radius(_ p: SenderMap.Point) -> CGFloat {
        min(2.5 + sqrt(CGFloat(p.stat.count)) * 0.55, 18)
    }

    private func nearest(_ location: CGPoint, _ size: CGSize, _ scale: CGFloat) -> SenderMap.Point? {
        var best: (SenderMap.Point, CGFloat)?
        for p in points {
            let c = position(p, size, scale)
            let d = hypot(c.x - location.x, c.y - location.y)
            if d <= radius(p) + 4, d < (best?.1 ?? .infinity) { best = (p, d) }
        }
        return best?.0
    }

    // MARK: - Selection

    private func select(_ size: CGSize, _ scale: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard hypot(value.translation.width, value.translation.height) > 4 else { return }
                box = CGRect(origin: value.startLocation, size: .zero)
                    .union(CGRect(origin: value.location, size: .zero))
            }
            .onEnded { value in
                let additive = NSEvent.modifierFlags.contains(.shift) || NSEvent.modifierFlags.contains(.command)
                if let rect = box {
                    let inside = points.filter { rect.contains(position($0, size, scale)) }.map(\.id)
                    model.selection = additive ? model.selection.union(inside) : Set(inside)
                } else if let p = nearest(value.location, size, scale) {
                    if model.selection.contains(p.id) { model.selection.remove(p.id) } else { model.selection.insert(p.id) }
                } else if !additive {
                    model.selection = []
                }
                box = nil
            }
    }

    private func members(_ cluster: SenderMap.Cluster) -> [String] {
        points.filter { $0.cluster == cluster.id }.map(\.id)
    }

    private func clusterSelected(_ cluster: SenderMap.Cluster) -> Bool {
        let ids = members(cluster)
        return !ids.isEmpty && ids.allSatisfy(model.selection.contains)
    }

    private func toggle(_ cluster: SenderMap.Cluster) {
        let ids = members(cluster)
        if clusterSelected(cluster) { model.selection.subtract(ids) } else { model.selection.formUnion(ids) }
    }
}

private struct ClusterLabel: View {
    let cluster: SenderMap.Cluster
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 1) {
                Text(cluster.topSenders.prefix(2).joined(separator: " · "))
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                Text("\(cluster.senders) 位 · \(Fmt.count(cluster.messages)) 封")
                    .font(.system(size: 10).monospacedDigit())
                    .opacity(0.6)
            }
            .foregroundStyle(selected ? Theme.paper : Theme.ink)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(selected ? Theme.ink : Theme.canvas.opacity(hovering ? 1 : 0.85), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.hairline))
            .frame(maxWidth: 220)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct SenderCard: View {
    let stat: SenderStat

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(stat.name.isEmpty ? stat.address : stat.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            if !stat.name.isEmpty { Text(stat.address).font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1) }
            HStack(spacing: 8) {
                Text("\(Fmt.count(stat.count)) 封").font(.system(size: 11, weight: .medium).monospacedDigit())
                Text("最新 " + Fmt.day.string(from: stat.latest)).font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.muted)
            }
            Text(stat.account).font(.system(size: 10)).foregroundStyle(Theme.faint).lineLimit(1)
        }
        .padding(10)
        .frame(width: 236, alignment: .leading)
        .background(Theme.canvas, in: RoundedRectangle(cornerRadius: Theme.radius))
        .hairlineBorder()
        .shadow(color: .black.opacity(0.08), radius: 8, y: 3)
    }
}
