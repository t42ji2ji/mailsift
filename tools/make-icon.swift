import AppKit
// 產生 MailSift 圖示。三個候選都是信封，畫在 App 的紙／墨單色裡，唯一的橘色是旗標：
//   a  實心墨色信封，右上角插一支橘旗
//   b  線條信封，右下壓一個放大鏡，鏡片裡一顆橘點（用意思搜信）
//   c  打開的信封，升起的信紙上是信件列，其中一列帶橘旗（篩信）
//   d  純白底 5×5 墨點，正中那格換成橘色送出紙飛機（定案，2026-10-13 跟 GPT 來回出的）
// 用法：swift tools/make-icon.swift <a|b|c|d> <root>   → build/AppIcon.iconset + Resources/AppIcon.icns
//       swift tools/make-icon.swift preview <root>   → build/icon-{a,b,c}.png + build/icon-options.png（不動 Resources）
// macOS 圖示格線：1024 畫布、824 主體、圓角 185，主體下方留陰影
func gray(_ w: CGFloat) -> CGColor { CGColor(gray: w, alpha: 1) }
let ink = gray(0.09)
let canvas = gray(0.965)                 // Theme.canvas（淺色）
let muted = gray(0.66)                   // 摘要行（比 App 的 faint 深一點，小尺寸才看得到）
let orange = CGColor(red: 0xD6 / 255.0, green: 0x4A / 255.0, blue: 0x29 / 255.0, alpha: 1)

func draw(_ variant: String, _ s: CGFloat) -> NSImage {
    NSImage(size: NSSize(width: s, height: s), flipped: true) { _ in
        let ctx = NSGraphicsContext.current!.cgContext
        ctx.scaleBy(x: s / 1024, y: s / 1024)
        let body = CGRect(x: 100, y: 100, width: 824, height: 824)
        let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 10 * s / 1024), blur: 24 * s / 1024, color: NSColor.black.withAlphaComponent(0.28).cgColor)
        ctx.addPath(shape); ctx.setFillColor(variant == "d" ? gray(1) : canvas); ctx.fillPath()
        ctx.restoreGState()
        ctx.addPath(shape); ctx.clip()
        func rr(_ r: CGRect, _ radius: CGFloat, _ c: CGColor) {
            ctx.setFillColor(c)
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)); ctx.fillPath()
        }
        func bar(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ c: CGColor) { rr(CGRect(x: x, y: y, width: w, height: h), min(w, h) / 2, c) }
        let tile = variant == "d" ? gray(1) : canvas
        // 外圍描一圈底色，讓疊在上面的形狀和底下分開
        func halo(_ draw: () -> Void, _ width: CGFloat) {
            ctx.saveGState(); ctx.setLineWidth(width * 2); ctx.setStrokeColor(tile); ctx.setLineJoin(.round)
            draw(); ctx.strokePath(); ctx.restoreGState()
        }
        func flagWithHalo(_ x: CGFloat, _ y: CGFloat, _ h: CGFloat) {
            // 旗標（同 flag.fill）用手畫：旗桿＋波浪旗面，才能描底色外框
            let w = h * 0.86, pole = h * 0.13
            let path = CGMutablePath()
            path.addRoundedRect(in: CGRect(x: x, y: y, width: pole, height: h), cornerWidth: pole / 2, cornerHeight: pole / 2)
            let t = y + h * 0.02, b = y + h * 0.60, l = x + pole * 0.5, r = x + w
            let face = CGMutablePath()
            face.move(to: CGPoint(x: l, y: t))
            face.addCurve(to: CGPoint(x: r, y: t + h * 0.04), control1: CGPoint(x: l + w * 0.35, y: t - h * 0.12), control2: CGPoint(x: l + w * 0.55, y: t + h * 0.14))
            face.addLine(to: CGPoint(x: r, y: b))
            face.addCurve(to: CGPoint(x: l, y: b - h * 0.02), control1: CGPoint(x: l + w * 0.55, y: b + h * 0.10), control2: CGPoint(x: l + w * 0.35, y: b - h * 0.16))
            face.closeSubpath()
            path.addPath(face)
            halo({ ctx.addPath(path) }, h * 0.09)
            ctx.addPath(path); ctx.setFillColor(orange); ctx.fillPath()
        }
        switch variant {
        case "a":
            // 實心墨色信封，封口 V 是底色線；右上角插一支橘旗
            let env = CGRect(x: 168, y: 352, width: 608, height: 432)
            rr(env, 80, ink)
            ctx.setStrokeColor(tile); ctx.setLineWidth(44); ctx.setLineCap(.round); ctx.setLineJoin(.round)
            ctx.move(to: CGPoint(x: 264, y: 440)); ctx.addLine(to: CGPoint(x: 472, y: 596)); ctx.addLine(to: CGPoint(x: 680, y: 440))
            ctx.strokePath()
            flagWithHalo(728, 240, 176)
        case "b":
            // 線條信封＋右下壓一個放大鏡，鏡片裡一顆橘點
            ctx.setStrokeColor(ink); ctx.setLineWidth(48); ctx.setLineCap(.round); ctx.setLineJoin(.round)
            let env = CGRect(x: 200, y: 264, width: 480, height: 344)
            ctx.addPath(CGPath(roundedRect: env, cornerWidth: 72, cornerHeight: 72, transform: nil)); ctx.strokePath()
            ctx.move(to: CGPoint(x: 272, y: 336)); ctx.addLine(to: CGPoint(x: 440, y: 464)); ctx.addLine(to: CGPoint(x: 608, y: 336))
            ctx.strokePath()
            let c = CGPoint(x: 656, y: 616), R: CGFloat = 120
            ctx.setFillColor(tile)
            ctx.fillEllipse(in: CGRect(x: c.x - R - 52, y: c.y - R - 52, width: (R + 52) * 2, height: (R + 52) * 2))
            ctx.setLineWidth(52)
            ctx.strokeEllipse(in: CGRect(x: c.x - R, y: c.y - R, width: R * 2, height: R * 2))
            ctx.setLineWidth(72)
            ctx.move(to: CGPoint(x: c.x + R * 0.72 + 20, y: c.y + R * 0.72 + 20)); ctx.addLine(to: CGPoint(x: 800, y: 760)); ctx.strokePath()
            ctx.setFillColor(orange)
            ctx.fillEllipse(in: CGRect(x: c.x - 48, y: c.y - 48, width: 96, height: 96))
        case "d":
            // 5×5 墨點，間距 123；中心那格是實心紙飛機，約兩顆點寬，朝右上
            for r in -2...2 { for c in -2...2 where r != 0 || c != 0 {
                let x = 512 + CGFloat(c) * 123, y = 512 + CGFloat(r) * 123
                ctx.setFillColor(ink); ctx.fillEllipse(in: CGRect(x: x - 32, y: y - 32, width: 64, height: 64))
            } }
            let k: CGFloat = 0.92
            let pts: [(CGFloat, CGFloat)] = [(71, -69), (-71, -17), (-34, 16), (12, -15), (-18, 33), (6, 68)]
            let plane = CGMutablePath()
            plane.addLines(between: pts.map { CGPoint(x: 512 + $0.0 * k, y: 512 + $0.1 * k) }); plane.closeSubpath()
            ctx.setFillColor(orange); ctx.setStrokeColor(orange); ctx.setLineWidth(10); ctx.setLineJoin(.round)
            ctx.addPath(plane); ctx.drawPath(using: .fillStroke)
        default: // c
            // 打開的信封：背板、升起的信紙（信件列＋橘旗）、前面的口袋
            rr(CGRect(x: 160, y: 448, width: 704, height: 384), 72, ink)
            let paperRect = CGRect(x: 256, y: 192, width: 512, height: 480)
            rr(paperRect, 48, gray(0.995))
            bar(320, 256, 256, 56, ink)
            bar(320, 344, 384, 32, muted)
            flagWithHalo(656, 244, 80)
            bar(320, 424, 224, 56, ink)
            bar(320, 512, 320, 32, muted)
            let pocket = CGMutablePath()
            pocket.move(to: CGPoint(x: 160, y: 520)); pocket.addLine(to: CGPoint(x: 512, y: 704)); pocket.addLine(to: CGPoint(x: 864, y: 520))
            pocket.addLine(to: CGPoint(x: 864, y: 832)); pocket.addLine(to: CGPoint(x: 160, y: 832)); pocket.closeSubpath()
            ctx.saveGState()
            ctx.addPath(CGPath(roundedRect: CGRect(x: 160, y: 448, width: 704, height: 384), cornerWidth: 72, cornerHeight: 72, transform: nil)); ctx.clip()
            halo({ ctx.addPath(pocket) }, 16)
            ctx.addPath(pocket); ctx.setFillColor(ink); ctx.fillPath()
            ctx.restoreGState()
        }
        return true
    }
}
func bitmap(_ w: Int, _ h: Int) -> NSBitmapImageRep {
    NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
}
func png(_ img: NSImage, _ px: Int) -> Data {
    let rep = bitmap(px, px)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    img.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}
// 比較表：上排淺灰底、下排深底；每格 256px 大圖，下面 32px 與 16px 實際像素（先縮再貼，不放大）
func sheet() -> Data {
    let variants = ["a", "b", "c", "d"], colW = 340, rowH = 420, W = colW * 4 + 40, H = rowH * 2
    let rep = bitmap(W, H)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    for (row, bg) in [NSColor(white: 0.92, alpha: 1), NSColor(white: 0.12, alpha: 1)].enumerated() {
        let y0 = CGFloat(H - (row + 1) * rowH)   // AppKit 原點在左下
        bg.setFill(); NSRect(x: 0, y: y0, width: CGFloat(W), height: CGFloat(rowH)).fill()
        for (i, v) in variants.enumerated() {
            let cx = CGFloat(20 + i * colW + colW / 2)
            let label = NSAttributedString(string: v.uppercased(), attributes: [
                .font: NSFont.systemFont(ofSize: 22, weight: .semibold),
                .foregroundColor: row == 0 ? NSColor(white: 0.2, alpha: 1) : NSColor(white: 0.85, alpha: 1)])
            label.draw(at: NSPoint(x: cx - label.size().width / 2, y: y0 + CGFloat(rowH) - 40))
            draw(v, 256).draw(in: NSRect(x: cx - 128, y: y0 + 100, width: 256, height: 256))
            for (px, dx) in [(32, -30), (16, 22)] {
                let small = NSImage(data: png(draw(v, CGFloat(px)), px))!
                small.draw(in: NSRect(x: cx + CGFloat(dx) - CGFloat(px) / 2, y: y0 + 40, width: CGFloat(px), height: CGFloat(px)))
            }
        }
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let args = CommandLine.arguments
let mode = args.count > 1 ? args[1] : "preview"
let root = URL(fileURLWithPath: args.count > 2 ? args[2] : ".")
let build = root.appendingPathComponent("build")
try! FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
if mode == "preview" {
    for v in ["a", "b", "c", "d"] {
        try! png(draw(v, 1024), 1024).write(to: build.appendingPathComponent("icon-\(v).png"))
    }
    try! sheet().write(to: build.appendingPathComponent("icon-options.png"))
} else {
    guard ["a", "b", "c", "d"].contains(mode) else { fatalError("variant 要是 a、b、c、d 或 preview") }
    let set = build.appendingPathComponent("AppIcon.iconset")
    try? FileManager.default.removeItem(at: set)
    try! FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
    for base in [16, 32, 128, 256, 512] {
        try! png(draw(mode, CGFloat(base)), base).write(to: set.appendingPathComponent("icon_\(base)x\(base).png"))
        try! png(draw(mode, CGFloat(base * 2)), base * 2).write(to: set.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
    }
    let res = root.appendingPathComponent("Resources")
    try! FileManager.default.createDirectory(at: res, withIntermediateDirectories: true)
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    p.arguments = ["-c", "icns", set.path, "-o", res.appendingPathComponent("AppIcon.icns").path]
    try! p.run(); p.waitUntilExit()
}
