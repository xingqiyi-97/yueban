import AppKit
import Foundation
import Vision
import CoreImage

// MARK: - 基础工具

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1.0) {
        self.init(calibratedRed: CGFloat((hex >> 16) & 0xFF) / 255.0,
                  green: CGFloat((hex >> 8) & 0xFF) / 255.0,
                  blue: CGFloat(hex & 0xFF) / 255.0,
                  alpha: alpha)
    }
}

private let fmt: DateFormatter = {
    let f = DateFormatter()
    f.calendar = Calendar(identifier: .gregorian)
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd"
    return f
}()

func dayKey(_ d: Date) -> String { fmt.string(from: d) }
func dateOfKey(_ s: String) -> Date? { fmt.date(from: s) }
func midnight(_ d: Date) -> Date { Calendar.current.startOfDay(for: d) }
func dayGap(_ a: Date, _ b: Date) -> Int {
    Calendar.current.dateComponents([.day], from: midnight(a), to: midnight(b)).day ?? 0
}
func addDays(_ d: Date, _ n: Int) -> Date {
    Calendar.current.date(byAdding: .day, value: n, to: d) ?? d
}
func isDark() -> Bool {
    NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
}

// MARK: - 激素期

enum Phase: String {
    case none
    case menstrual   // 月经期
    case follicular  // 卵泡期
    case ovulation   // 排卵期
    case luteal      // 黄体期
    case late        // 预测经期已到 / 推迟

    var title: String {
        switch self {
        case .none:       return "待记录"
        case .menstrual:  return "月经期"
        case .follicular: return "卵泡期"
        case .ovulation:  return "排卵期"
        case .luteal:     return "黄体期"
        case .late:       return "经期推迟"
        }
    }

    var color: NSColor {
        switch self {
        case .none:       return NSColor(hex: 0xB4B9C4)
        case .menstrual:  return NSColor(hex: 0xFF7A94)
        case .follicular: return NSColor(hex: 0x3FC0A0)
        case .ovulation:  return NSColor(hex: 0x9B8CFF)
        case .luteal:     return NSColor(hex: 0xF5A94F)
        case .late:       return NSColor(hex: 0xE4606F)
        }
    }

    var tips: [String] {
        switch self {
        case .menstrual:  return ["别喝冰的，暖一暖", "补点铁，别硬撑", "今天允许你摆烂", "疼就吃药，别扛"]
        case .follicular: return ["状态回升，开新坑", "难啃的事放今天", "动一动，精力旺", "学新东西最省力"]
        case .ovulation:  return ["精力巅峰，冲 KPI", "重要会议安排上", "注意避孕或备孕", "社交也格外顺"]
        case .luteal:     return ["嘴馋正常，别自责", "少咖啡，早点睡", "情绪敏感是激素", "清淡点，少胀气"]
        case .late:       return ["来了就点日历记一下", "推迟几天也常见", "别焦虑，先保暖"]
        case .none:       return ["点日历标记第一天", "记满两次就能预测"]
        }
    }

    var tip: String {
        let list = tips
        let seed = Calendar.current.ordinality(of: .day, in: .year, for: midnight(Date())) ?? 1
        return list[seed % list.count]
    }
}

// MARK: - 数据

struct PetData: Codable {
    var marked: Set<String> = []
    var presetCycle: Int = 28
    var presetPeriod: Int = 5
    var originX: Double?
    var originY: Double?
}

struct CycleRun { var start: Date; var end: Date }

struct Status {
    var phase: Phase
    var cycleDay: Int
    var cycleLen: Int
    var periodLen: Int
    var daysToNext: Int      // >0 还有几天；0 就是今天；<0 已推迟
    var nextStart: Date
    var ovulation: Date
    var ovulationDay: Int
    var hasData: Bool

    var countdown: String {
        if !hasData { return "还没有记录" }
        if daysToNext > 0 { return "距下次经期还有 \(daysToNext) 天" }
        if daysToNext == 0 { return "预计就是今天 · 记得记录" }
        return "已推迟 \(-daysToNext) 天 · 来了点一下日历"
    }

    var dayText: String {
        guard hasData else { return "点日历标记第一天吧" }
        return "第 \(cycleDay) 天 · 周期 \(cycleLen) 天"
    }
}

// MARK: - 计算引擎

final class Engine {
    static let shared = Engine()

    var data: PetData {
        didSet { save() }
    }

    private let fileURL: URL

    init() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Yueban")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("data.json")
        if let raw = try? Data(contentsOf: fileURL),
           let d = try? JSONDecoder().decode(PetData.self, from: raw) {
            data = d
        } else {
            data = PetData()
        }
    }

    private func save() {
        if let raw = try? JSONEncoder().encode(data) {
            try? raw.write(to: fileURL, options: .atomic)
        }
    }

    func toggle(_ date: Date) {
        let k = dayKey(date)
        if data.marked.contains(k) { data.marked.remove(k) } else { data.marked.insert(k) }
    }

    func isMarked(_ date: Date) -> Bool { data.marked.contains(dayKey(date)) }

    /// 把已标记的日期合并成一段段连续的经期（中间漏记 1 天也算同一段）
    func runs() -> [CycleRun] {
        let days = data.marked.compactMap(dateOfKey).map(midnight).sorted()
        let today = midnight(Date())
        let days2 = days.filter { $0 <= today }
        guard !days2.isEmpty else { return [] }
        var out: [CycleRun] = []
        var s = days2[0]
        var e = days2[0]
        for d in days2.dropFirst() {
            if dayGap(e, d) <= 2 { e = d } else {
                out.append(CycleRun(start: s, end: e)); s = d; e = d
            }
        }
        out.append(CycleRun(start: s, end: e))
        return out
    }

    var avgCycle: Int {
        let rs = runs()
        guard rs.count >= 2 else { return data.presetCycle }
        var gaps: [Int] = []
        for i in 1..<rs.count {
            let g = dayGap(rs[i - 1].start, rs[i].start)
            if (15...60).contains(g) { gaps.append(g) }
        }
        guard !gaps.isEmpty else { return data.presetCycle }
        let use = Array(gaps.suffix(6))
        return Int((Double(use.reduce(0, +)) / Double(use.count)).rounded())
    }

    var avgPeriod: Int {
        let rs = runs()
        let today = midnight(Date())
        let done = rs.filter { dayGap($0.end, today) >= 2 }
        if !done.isEmpty {
            let lens = Array(done.suffix(6)).map { dayGap($0.start, $0.end) + 1 }
            let avg = Int((Double(lens.reduce(0, +)) / Double(lens.count)).rounded())
            if (1...12).contains(avg) { return avg }
        }
        return data.presetPeriod
    }

    func ovulationDay(cycleLen: Int, periodLen: Int) -> Int {
        var d = cycleLen - 14
        d = max(d, periodLen + 1)
        d = min(d, cycleLen - 3)
        return d
    }

    func status() -> Status {
        let rs = runs()
        let today = midnight(Date())
        let cycleLen = avgCycle
        let periodLen = avgPeriod
        guard let last = rs.last else {
            return Status(phase: .none, cycleDay: 0, cycleLen: cycleLen, periodLen: periodLen,
                          daysToNext: 0, nextStart: today, ovulation: today,
                          ovulationDay: ovulationDay(cycleLen: cycleLen, periodLen: periodLen), hasData: false)
        }
        let d = dayGap(last.start, today) + 1
        let recordedLen = dayGap(last.start, last.end) + 1
        let effPeriod = max(recordedLen, periodLen)
        let nextStart = addDays(last.start, cycleLen)
        let ovDay = ovulationDay(cycleLen: cycleLen, periodLen: effPeriod)
        let ovulation = addDays(last.start, ovDay - 1)
        let daysToNext = dayGap(today, nextStart)

        var phase: Phase
        if d <= effPeriod {
            phase = .menstrual
        } else if daysToNext <= 0 {
            phase = .late
        } else if d < ovDay - 3 {
            phase = .follicular
        } else if d <= ovDay + 1 {
            phase = .ovulation
        } else {
            phase = .luteal
        }

        return Status(phase: phase, cycleDay: d, cycleLen: cycleLen, periodLen: effPeriod,
                      daysToNext: daysToNext, nextStart: nextStart, ovulation: ovulation,
                      ovulationDay: ovDay, hasData: true)
    }

    /// 未来若干次经期的预测（含当前这一次）
    func predictedDays(cycles: Int = 8) -> Set<String> {
        guard let last = runs().last else { return [] }
        let cycleLen = avgCycle
        let periodLen = avgPeriod
        var out: Set<String> = []
        for k in 0..<cycles {
            let s = addDays(last.start, k * cycleLen)
            for i in 0..<periodLen { out.insert(dayKey(addDays(s, i))) }
        }
        return out
    }

    func predictedOvulationDays(cycles: Int = 8) -> Set<String> {
        guard let last = runs().last else { return [] }
        let cycleLen = avgCycle
        let periodLen = avgPeriod
        let ovDay = ovulationDay(cycleLen: cycleLen, periodLen: periodLen)
        var out: Set<String> = []
        for k in 0..<cycles {
            out.insert(dayKey(addDays(addDays(last.start, k * cycleLen), ovDay - 1)))
        }
        return out
    }
}

// MARK: - 自定义形象（照片 → 桌宠，全部在本机完成，不联网、不上传）

final class AvatarStore {
    static let shared = AvatarStore()

    enum MakeResult {
        case ok(NSImage)
        case failed(String)
    }

    private let dir: URL = {
        let d = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Yueban")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
    private var fileURL: URL { dir.appendingPathComponent("avatar.png") }

    private(set) var image: NSImage?

    init() {
        if let img = NSImage(contentsOfFile: fileURL.path), img.isValid { image = img }
    }

    var hasCustom: Bool { image != nil }

    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
        image = nil
    }

    /// 照片 → 抠主体 → 白色贴纸边 → 存本机（saveTo 仅供离线自检测试重定向输出）
    func make(from url: URL, saveTo customURL: URL? = nil) -> MakeResult {
        guard let src = NSImage(contentsOf: url), src.isValid else {
            return .failed("这张图片打不开，换一张试试")
        }
        guard src.cgImage(forProposedRect: nil, context: nil, hints: nil) != nil else {
            return .failed("这张图片读不出来，换一张试试")
        }

        // 1) 优先用 Vision 自动抠出主体（macOS 14+，本机完成）
        if let cut = Self.foregroundCutout(src), Self.alphaRatio(cut) < 0.85 {   // 前景太少说明是风景照，走圆形降级
            return finish(cut, to: customURL)
        }
        // 2) 抠不出来（风景照 / 老系统）→ 降级成圆形头像，一样能用
        return finish(Self.circular(src, side: 420), to: customURL)
    }

    // MARK: 处理

    /// Vision 生成主体遮罩 → 合成透明背景图 → 裁到主体范围
    private static func foregroundCutout(_ src: NSImage) -> NSImage? {
        guard #available(macOS 14.0, *) else { return nil }
        guard let cg = scaled(src, maxSide: 1024).cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }

        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        do { try handler.perform([request]) } catch { debugLog("vision perform error: \(error)"); return nil }
        guard let obs = request.results?.first else { debugLog("vision no results"); return nil }

        do {
            let pb = try obs.generateMask(forInstances: obs.allInstances)
            let fmt = CVPixelBufferGetPixelFormatType(pb)
            CVPixelBufferLockBaseAddress(pb, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddress(pb) else { debugLog("no base address"); return nil }
            let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
            let bpr = CVPixelBufferGetBytesPerRow(pb)
            let raw0 = UnsafeRawBufferPointer(start: base, count: bpr * h)

            // 统一转成 8-bit 灰度 mask（去掉行尾 padding）
            var maskBytes = [UInt8](repeating: 0, count: w * h)
            switch fmt {
            case kCVPixelFormatType_OneComponent8:
                for y in 0..<h {
                    for x in 0..<w { maskBytes[y * w + x] = raw0[y * bpr + x] }
                }
            case kCVPixelFormatType_OneComponent32Float:   // 'L00f'，Vision 实际返回的格式
                for y in 0..<h {
                    let row = y * bpr
                    for x in 0..<w {
                        let bits = UInt32(raw0[row + x * 4])
                            | (UInt32(raw0[row + x * 4 + 1]) << 8)
                            | (UInt32(raw0[row + x * 4 + 2]) << 16)
                            | (UInt32(raw0[row + x * 4 + 3]) << 24)
                        let v = Float(bitPattern: bits)
                        maskBytes[y * w + x] = UInt8(max(0, min(1, v)) * 255)
                    }
                }
            default:
                debugLog("unexpected mask format"); return nil
            }

            // mask 分辨率可能与原图不同（Vision 内部模型分辨率），先重采样到原图尺寸
            let W = cg.width, H = cg.height
            var finalMask = maskBytes
            if w != W || h != H {
                guard let grayProvider = CGDataProvider(data: Data(maskBytes) as CFData),
                      let gray = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8,
                                         bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                         bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                         provider: grayProvider, decode: nil,
                                         shouldInterpolate: false, intent: .defaultIntent) else { debugLog("gray fail"); return nil }
                var resampled = [UInt8](repeating: 0, count: W * H)
                let drew = resampled.withUnsafeMutableBytes { ptr -> Bool in
                    guard let ctx = CGContext(data: ptr.baseAddress, width: W, height: H,
                                              bitsPerComponent: 8, bytesPerRow: W,
                                              space: CGColorSpaceCreateDeviceGray(),
                                              bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
                    ctx.interpolationQuality = .high
                    ctx.draw(gray, in: CGRect(x: 0, y: 0, width: W, height: H))
                    return true
                }
                guard drew else { debugLog("resample fail"); return nil }
                finalMask = resampled
                debugLog("mask \(w)x\(h) resampled to \(W)x\(H)")
            }

            // 主体范围（采样扫描）
            var minX = W, minY = H, maxX = 0, maxY = 0
            let step = max(1, W / 300)
            for y in stride(from: 0, to: H, by: step) {
                for x in stride(from: 0, to: W, by: step) where finalMask[y * W + x] > 40 {
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                    if y < minY { minY = y }
                    if y > maxY { maxY = y }
                }
            }
            guard maxX > minX, maxY > minY else { debugLog("empty mask"); return nil }
            debugLog("mask box (\(minX),\(minY)) \(maxX - minX + 1)x\(maxY - minY + 1) of \(W)x\(H)")

            // 构造 CGImage mask：decode [1,0] 反转（Vision 前景=255，masking 里 0=绘制）
            let crop = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
            guard let provider = CGDataProvider(data: Data(finalMask) as CFData),
                  let mask = CGImage(maskWidth: W, height: H, bitsPerComponent: 8, bitsPerPixel: 8,
                                     bytesPerRow: W, provider: provider, decode: [1, 0],
                                     shouldInterpolate: false),
                  let masked = cg.masking(mask),
                  let cropped = masked.cropping(to: crop) else { debugLog("mask build failed"); return nil }
            return NSImage(cgImage: cropped, size: NSSize(width: cropped.width, height: cropped.height))
        } catch { debugLog("mask error: \(error)"); return nil }
    }

    private static func debugLog(_ s: String) {
        FileHandle.standardError.write(Data("[avatar] \(s)\n".utf8))
    }

    /// 不透明像素占比：接近 1 说明整张图都不透明（多半没抠成功）
    private static func alphaRatio(_ img: NSImage) -> CGFloat {
        guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return 1 }
        let w = 80, h = 80
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 1 }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let buf = ctx.data?.bindMemory(to: UInt8.self, capacity: w * h * 4) else { return 1 }
        var n = 0
        for i in 0..<(w * h) where buf[i * 4 + 3] > 40 { n += 1 }
        return CGFloat(n) / CGFloat(w * h)
    }

    private static func circular(_ img: NSImage, side: CGFloat) -> NSImage {
        let out = NSImage(size: NSSize(width: side, height: side))
        out.lockFocus()
        NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: side, height: side)).addClip()
        let s = max(side / img.size.width, side / img.size.height)
        let w = img.size.width * s, h = img.size.height * s
        img.draw(in: NSRect(x: (side - w) / 2, y: (side - h) / 2, width: w, height: h),
                 from: .zero, operation: .sourceOver, fraction: 1)
        out.unlockFocus()
        return out
    }

    private static func scaled(_ img: NSImage, maxSide: CGFloat) -> NSImage {
        let s = min(1, maxSide / max(img.size.width, img.size.height))
        if s >= 1 { return img }
        let size = NSSize(width: img.size.width * s, height: img.size.height * s)
        let out = NSImage(size: size)
        out.lockFocus()
        img.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .copy, fraction: 1)
        out.unlockFocus()
        return out
    }

    /// 贴纸白边：把图变白色剪影，沿 16 个方向偏移画一圈，再压上原图
    private static func sticker(_ img: NSImage, border: CGFloat) -> NSImage {
        let sil = silhouette(img, .white)
        let out = NSImage(size: NSSize(width: img.size.width + border * 2,
                                       height: img.size.height + border * 2))
        out.lockFocus()
        let r = img.size
        for i in 0..<16 {
            let a = CGFloat(i) * .pi / 8
            sil.draw(in: NSRect(x: border + cos(a) * border, y: border + sin(a) * border,
                                width: r.width, height: r.height),
                     from: .zero, operation: .sourceOver, fraction: 1)
        }
        img.draw(in: NSRect(x: border, y: border, width: r.width, height: r.height),
                 from: .zero, operation: .sourceOver, fraction: 1)
        out.unlockFocus()
        return out
    }

    private static func silhouette(_ img: NSImage, _ color: NSColor) -> NSImage {
        let size = img.size
        let out = NSImage(size: size)
        out.lockFocus()
        img.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .sourceOver, fraction: 1)
        color.set()
        NSRect(origin: .zero, size: size).fill(using: .sourceAtop)
        out.unlockFocus()
        return out
    }

    private func finish(_ img: NSImage, to customURL: URL?) -> MakeResult {
        let ready = Self.sticker(Self.scaled(img, maxSide: 400), border: 5)
        guard let tiff = ready.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            return .failed("处理失败了，换一张图片试试")
        }
        let dest = customURL ?? fileURL
        do { try png.write(to: dest) } catch { return .failed("存不进去，换个位置再试") }
        if customURL == nil { image = NSImage(contentsOfFile: dest.path) ?? ready }
        return .ok(ready)
    }
}

// MARK: - 桌宠画法

final class PetView: NSView {
    var phase: Phase = .none { didSet { needsDisplay = true } }
    var awake: Bool? = nil   // nil = 自动眨眼；图标渲染时强制睁眼
    /// 自定义形象（照片抠图）；nil = 默认 Hello Kitty
    var avatar: NSImage? { didSet { needsDisplay = true } }
    private var timer: Timer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let t = Timer(timeInterval: 1.0 / 24.0, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { timer?.invalidate() }

    override var isFlipped: Bool { true }

    @objc private func tick() { needsDisplay = true }

    private func shadow(_ on: Bool) {
        if on {
            let s = NSShadow()
            s.shadowColor = NSColor(calibratedWhite: 0, alpha: 0.18)
            s.shadowBlurRadius = 7
            s.shadowOffset = NSSize(width: 0, height: -2)
            s.set()
        } else {
            NSShadow().set()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // 设计稿 108 x 152，按 bounds 等比缩放居中
        let designW: CGFloat = 108
        let designH: CGFloat = 152
        let s = min(bounds.width / designW, bounds.height / designH)
        NSGraphicsContext.saveGraphicsState()
        let gctx = NSGraphicsContext.current!.cgContext
        gctx.translateBy(x: (bounds.width - designW * s) / 2,
                         y: (bounds.height - designH * s) / 2)
        gctx.scaleBy(x: s, y: s)
        defer { NSGraphicsContext.restoreGraphicsState() }

        let t = Date().timeIntervalSince1970
        let accent = phase.color                       // 挂件用当期颜色
        let brown = NSColor(hex: 0x6E4B38)             // 手绘风棕色描边
        let cx: CGFloat = 54
        let bob = CGFloat(sin(t * 1.6)) * 2.5
        let top: CGFloat = 40 + bob
        let bw: CGFloat = 82
        let bh: CGFloat = 72
        let body = CGRect(x: cx - bw / 2, y: top, width: bw, height: bh)

        // 虚线手绘描边
        func sketch(_ path: NSBezierPath, dash: CGFloat, phase: CGFloat = 0, width: CGFloat = 1.7) {
            NSColor(hex: 0xFFFEFB).setFill()
            path.fill()
            brown.setStroke()
            path.lineWidth = width
            path.lineJoinStyle = .round
            path.setLineDash([dash, dash * 0.7], count: 2, phase: phase)
            path.stroke()
            path.setLineDash([], count: 0, phase: 0)
        }

        // 自定义形象：直接用照片抠出来的贴纸
        if let av = avatar {
            drawAvatar(av, cx: cx, bob: bob, accent: accent)
            return
        }

        shadow(false)
        NSColor(calibratedWhite: 0.25, alpha: 0.10).setFill()
        NSBezierPath(ovalIn: CGRect(x: cx - 26, y: 122, width: 52, height: 7)).fill()

        shadow(true)

        // 耳朵
        drawEar(cx: cx - 27, baseY: top + 20, dir: -1, brown: brown, dashPhase: 0)
        drawEar(cx: cx + 27, baseY: top + 20, dir: 1, brown: brown, dashPhase: 3)

        // 头身一体
        let bodyPath = NSBezierPath(roundedRect: body, xRadius: 36, yRadius: 33)
        sketch(bodyPath, dash: 5, phase: 0.5, width: 1.7)

        // 小脚
        sketch(NSBezierPath(ovalIn: CGRect(x: cx - 37, y: top + 58, width: 24, height: 14)),
               dash: 3.6, phase: 0.8, width: 1.3)
        sketch(NSBezierPath(ovalIn: CGRect(x: cx + 13, y: top + 58, width: 24, height: 14)),
               dash: 3.6, phase: 2, width: 1.3)

        // 蝴蝶结（薄荷绿 + 粉玫瑰，压在头顶左侧）
        drawBow(at: CGPoint(x: cx - 28, y: top + 4), brown: brown)

        // 眼睛
        let eyeY = top + 38
        let blink = (awake != nil) ? !awake! : ((t.truncatingRemainder(dividingBy: 4.6)) < 0.14)
        let eyeBrown = NSColor(hex: 0x5A3B2E)
        for sx in [-17, 17] {
            let ex = cx + CGFloat(sx)
            if blink {
                let p = NSBezierPath()
                p.move(to: CGPoint(x: ex - 4.5, y: eyeY + 1))
                p.curve(to: CGPoint(x: ex + 4.5, y: eyeY + 1),
                        controlPoint1: CGPoint(x: ex - 2, y: eyeY - 3),
                        controlPoint2: CGPoint(x: ex + 2, y: eyeY - 3))
                p.lineWidth = 2
                p.lineCapStyle = .round
                eyeBrown.setStroke()
                p.stroke()
            } else {
                eyeBrown.setFill()
                NSBezierPath(ovalIn: CGRect(x: ex - 4, y: eyeY - 5, width: 8, height: 10.5)).fill()
            }
        }

        // 黄鼻子
        NSColor(hex: 0xF7D879).setFill()
        let nose = NSBezierPath(ovalIn: CGRect(x: cx - 4.6, y: eyeY + 8, width: 9.2, height: 6.6))
        nose.fill()
        brown.setStroke()
        nose.lineWidth = 1
        nose.stroke()

        // 腮红
        NSColor(hex: 0xF5AEBF, alpha: 0.5).setFill()
        NSBezierPath(ovalIn: CGRect(x: cx - 36, y: eyeY + 4, width: 12, height: 7)).fill()
        NSBezierPath(ovalIn: CGRect(x: cx + 24, y: eyeY + 4, width: 12, height: 7)).fill()

        // 胡须（微微上翘）
        brown.setStroke()
        for dir in [-1, 1] {
            for i in -1...1 {
                let p = NSBezierPath()
                let y0 = eyeY + 5 + CGFloat(i) * 4.5
                p.move(to: CGPoint(x: cx + CGFloat(dir) * 22, y: y0))
                p.curve(to: CGPoint(x: cx + CGFloat(dir) * 35, y: y0 + CGFloat(i) * 3 - 1.5),
                        controlPoint1: CGPoint(x: cx + CGFloat(dir) * 27, y: y0 + 1.2),
                        controlPoint2: CGPoint(x: cx + CGFloat(dir) * 31, y: y0 + CGFloat(i) * 1.6))
                p.lineWidth = 0.9
                p.lineCapStyle = .round
                p.stroke()
            }
        }

        // 阶段小挂件（右耳上方）
        drawBadge(phase, at: CGPoint(x: cx + 46, y: top - 3 + CGFloat(sin(t * 1.15 + 1.2)) * 2.5), color: accent)

        shadow(false)
    }

    /// 照片形象：贴地摆放 + 当期颜色的小垫子 + 右上角挂件
    private func drawAvatar(_ av: NSImage, cx: CGFloat, bob: CGFloat, accent: NSColor) {
        let groundY: CGFloat = 122
        shadow(false)

        NSColor(calibratedWhite: 0.25, alpha: 0.12).setFill()
        NSBezierPath(ovalIn: CGRect(x: cx - 30, y: groundY - 2, width: 60, height: 8)).fill()
        accent.withAlphaComponent(0.20).setFill()
        NSBezierPath(ovalIn: CGRect(x: cx - 26, y: groundY - 1, width: 52, height: 7)).fill()

        let boxW: CGFloat = 98
        let boxH: CGFloat = 94
        let s = min(boxW / av.size.width, boxH / av.size.height)
        let w = av.size.width * s
        let h = av.size.height * s
        let x = cx - w / 2
        let y = groundY - h + bob

        shadow(true)
        av.draw(in: CGRect(x: x, y: y, width: w, height: h),
                from: .zero, operation: .sourceOver, fraction: 1)
        shadow(false)

        drawBadge(phase, at: CGPoint(x: cx + 41, y: 44 + bob + CGFloat(sin(Date().timeIntervalSince1970 * 1.15 + 1.2)) * 2.0),
                  color: accent)
    }

    private func drawEar(cx: CGFloat, baseY: CGFloat, dir: CGFloat, brown: NSColor, dashPhase: CGFloat) {
        let w: CGFloat = 25
        let h: CGFloat = 26
        let p = NSBezierPath()
        p.move(to: CGPoint(x: cx - w / 2, y: baseY))
        p.line(to: CGPoint(x: cx + dir * 3, y: baseY - h))
        p.line(to: CGPoint(x: cx + w / 2, y: baseY))
        p.close()
        NSColor(hex: 0xFFFEFB).setFill()
        p.fill()
        brown.setStroke()
        p.lineWidth = 1.6
        p.lineJoinStyle = .round
        p.setLineDash([4, 2.8], count: 2, phase: dashPhase)
        p.stroke()
        p.setLineDash([], count: 0, phase: 0)
    }

    private func drawBow(at p: CGPoint, brown: NSColor) {
        let mint = NSColor(hex: 0xB7D8BA)
        let w: CGFloat = 13
        let h: CGFloat = 9.5
        let left = NSBezierPath()
        left.move(to: CGPoint(x: p.x - 2, y: p.y))
        left.line(to: CGPoint(x: p.x - 2 - w, y: p.y - h))
        left.line(to: CGPoint(x: p.x - 2 - w, y: p.y + h))
        left.close()
        let right = NSBezierPath()
        right.move(to: CGPoint(x: p.x + 2, y: p.y))
        right.line(to: CGPoint(x: p.x + 2 + w, y: p.y - h))
        right.line(to: CGPoint(x: p.x + 2 + w, y: p.y + h))
        right.close()
        mint.setFill()
        brown.setStroke()
        for path in [left, right] {
            path.fill()
            path.lineWidth = 1.4
            path.lineJoinStyle = .round
            path.stroke()
        }
        // 粉玫瑰：圆 + 螺旋
        let rose = NSColor(hex: 0xE8A2B8)
        let roseDark = NSColor(hex: 0xC97E9B)
        rose.setFill()
        NSBezierPath(ovalIn: CGRect(x: p.x - 5.4, y: p.y - 5.4, width: 10.8, height: 10.8)).fill()
        brown.setStroke()
        let knot = NSBezierPath(ovalIn: CGRect(x: p.x - 5.4, y: p.y - 5.4, width: 10.8, height: 10.8))
        knot.lineWidth = 1
        knot.stroke()
        roseDark.setStroke()
        let spiral = NSBezierPath()
        spiral.appendArc(withCenter: p, radius: 3.7, startAngle: 40, endAngle: 260, clockwise: false)
        spiral.appendArc(withCenter: CGPoint(x: p.x + 0.7, y: p.y + 0.5), radius: 1.9, startAngle: 250, endAngle: 70, clockwise: false)
        spiral.lineWidth = 1
        spiral.lineCapStyle = .round
        spiral.stroke()
    }

    private func drawBadge(_ phase: Phase, at p: CGPoint, color: NSColor) {
        let s: CGFloat = 8
        var path = NSBezierPath()
        switch phase {
        case .menstrual: // 水滴
            path.append(NSBezierPath(ovalIn: CGRect(x: p.x - s * 0.8, y: p.y - s * 0.35, width: s * 1.6, height: s * 1.6)))
            let tri = NSBezierPath()
            tri.move(to: CGPoint(x: p.x - s * 0.7, y: p.y + s * 0.25))
            tri.line(to: CGPoint(x: p.x, y: p.y - s * 1.5))
            tri.line(to: CGPoint(x: p.x + s * 0.7, y: p.y + s * 0.25))
            tri.close()
            path.append(tri)
        case .follicular: // 叶子
            path.move(to: CGPoint(x: p.x - s, y: p.y + s * 0.55))
            path.curve(to: CGPoint(x: p.x + s, y: p.y - s * 0.55),
                       controlPoint1: CGPoint(x: p.x - s * 0.4, y: p.y - s * 0.85),
                       controlPoint2: CGPoint(x: p.x + s * 0.4, y: p.y - s * 1.0))
            path.curve(to: CGPoint(x: p.x - s, y: p.y + s * 0.55),
                       controlPoint1: CGPoint(x: p.x + s * 0.45, y: p.y + s * 0.25),
                       controlPoint2: CGPoint(x: p.x - s * 0.4, y: p.y + s * 0.45))
            path.close()
        case .ovulation: // 四角星
            let outer: CGFloat = s * 1.15
            let inner: CGFloat = s * 0.32
            for i in 0..<8 {
                let r: CGFloat = (i % 2 == 0) ? outer : inner
                let a = CGFloat(i) * .pi / 4.0 - .pi / 2
                let pt = CGPoint(x: p.x + cos(a) * r, y: p.y + sin(a) * r)
                if i == 0 { path.move(to: pt) } else { path.line(to: pt) }
            }
            path.close()
        case .luteal: // 月亮
            path.append(NSBezierPath(ovalIn: CGRect(x: p.x - s, y: p.y - s, width: s * 2, height: s * 2)))
            path.append(NSBezierPath(ovalIn: CGRect(x: p.x - s * 0.5, y: p.y - s * 0.85, width: s * 2, height: s * 2)))
            path.windingRule = .evenOdd
        case .late: // 感叹号
            path.append(NSBezierPath(roundedRect: CGRect(x: p.x - s * 0.3, y: p.y - s, width: s * 0.6, height: s * 1.3),
                                     xRadius: s * 0.3, yRadius: s * 0.3))
            path.append(NSBezierPath(ovalIn: CGRect(x: p.x - s * 0.3, y: p.y + s * 0.6, width: s * 0.6, height: s * 0.6)))
        case .none: // 小圆
            path = NSBezierPath(ovalIn: CGRect(x: p.x - s * 0.8, y: p.y - s * 0.8, width: s * 1.6, height: s * 1.6))
        }
        color.setFill()
        path.fill()
        NSColor.white.withAlphaComponent(0.55).setFill()
        path.fill() // 淡淡提亮，避免深色背景看不清
        color.setStroke()
        path.lineWidth = 1.6
        path.lineJoinStyle = .round
        path.stroke()
    }
}

// MARK: - 气泡便利贴

final class BubbleView: NSView {
    var title = "" { didSet { needsDisplay = true } }
    var tip = "" { didSet { needsDisplay = true } }
    var foot = "" { didSet { needsDisplay = true } }
    var dotColor: NSColor = .gray { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let r = bounds.insetBy(dx: 3, dy: 3)
        let dark = isDark()
        let bg = dark ? NSColor(hex: 0x2B2B30, alpha: 0.94) : NSColor(hex: 0xFFFFFF, alpha: 0.94)

        let sh = NSShadow()
        sh.shadowColor = NSColor(calibratedWhite: 0, alpha: 0.16)
        sh.shadowBlurRadius = 10
        sh.shadowOffset = NSSize(width: 0, height: -2)
        sh.set()

        let path = NSBezierPath(roundedRect: r, xRadius: 14, yRadius: 14)
        bg.setFill()
        path.fill()

        let tail = NSBezierPath()
        tail.move(to: CGPoint(x: r.minX + 2, y: 30))
        tail.line(to: CGPoint(x: r.minX - 8, y: 42))
        tail.line(to: CGPoint(x: r.minX + 2, y: 52))
        tail.close()
        tail.fill()

        NSShadow().set()
        NSColor(hex: 0x000000, alpha: dark ? 0.35 : 0.08).setStroke()
        path.lineWidth = 1
        path.stroke()

        dotColor.setFill()
        NSBezierPath(ovalIn: CGRect(x: 18, y: 17, width: 10, height: 10)).fill()

        drawText(title, x: 36, y: 15, w: r.width - 50, size: 15, weight: .semibold, color: .labelColor)
        drawText(tip, x: 18, y: 40, w: r.width - 36, size: 13.5, weight: .regular, color: .secondaryLabelColor)

        NSColor.separatorColor.withAlphaComponent(0.6).setStroke()
        let line = NSBezierPath()
        line.move(to: CGPoint(x: 18, y: 66))
        line.line(to: CGPoint(x: r.width - 18, y: 66))
        line.lineWidth = 1
        line.stroke()

        drawText(foot, x: 18, y: 70, w: r.width - 36, size: 11.5, weight: .regular, color: .tertiaryLabelColor)
    }

    private func drawText(_ s: String, x: CGFloat, y: CGFloat, w: CGFloat, size: CGFloat,
                          weight: NSFont.Weight, color: NSColor) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: color
        ]
        (s as NSString).draw(in: NSRect(x: x, y: y, width: w, height: size + 8), withAttributes: attrs)
    }
}

// MARK: - 桌宠窗口

final class PetRoot: NSView {
    var dragEnabled = true
    var onDoubleClick: (() -> Void)?
    override var isFlipped: Bool { true }
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDoubleClick?()
        } else if dragEnabled {
            window?.performDrag(with: event)
        }
    }
}

final class PetWindow: NSPanel {
    let root = PetRoot(frame: .zero)
    let petView = PetView(frame: .zero)
    let bubble = BubbleView(frame: .zero)

    init() {
        super.init(contentRect: NSRect(x: 120, y: 240, width: 344, height: 152),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isMovableByWindowBackground = true
        acceptsMouseMovedEvents = true

        contentView = root
        root.frame = NSRect(x: 0, y: 0, width: 344, height: 152)
        root.toolTip = "拖动我 · 双击打开日历 · 右键菜单"
        petView.frame = NSRect(x: 0, y: 0, width: 108, height: 152)
        bubble.frame = NSRect(x: 100, y: 18, width: 240, height: 100)
        root.addSubview(petView)
        root.addSubview(bubble)
    }

    func update(_ st: Status) {
        petView.phase = st.phase
        bubble.dotColor = st.phase.color
        bubble.title = st.phase.title + (st.hasData ? " · 第 \(st.cycleDay) 天" : "")
        bubble.tip = st.phase.tip
        bubble.foot = st.countdown
    }
}

// MARK: - 日历格子

class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

final class IconCanvasView: FlippedView {
    override func draw(_ dirtyRect: NSRect) {
        let bg = NSBezierPath(roundedRect: bounds.insetBy(dx: 64, dy: 64), xRadius: 210, yRadius: 210)
        NSGradient(starting: NSColor(hex: 0xF0F7EC), ending: NSColor(hex: 0xB7D8BA))?
            .draw(in: bg, angle: -70)
    }
}

final class DayCell: NSView {
    var date: Date?
    var inMonth = true
    var isPeriod = false
    var isPredicted = false
    var isOvulation = false
    var isToday = false
    var isFuture = false
    var onToggle: ((Date) -> Void)?

    override var isFlipped: Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let d = date, inMonth, !isFuture else { return }
        onToggle?(d)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let d = date else { return }
        let s: CGFloat = 34
        let cx = bounds.midX
        let cy = bounds.midY - 3
        let circle = CGRect(x: cx - s / 2, y: cy - s / 2, width: s, height: s)
        let comps = Calendar.current.dateComponents([.day], from: d)
        let text = "\(comps.day ?? 0)"

        if isPeriod {
            NSColor(hex: 0xFF7A94).setFill()
            NSBezierPath(ovalIn: circle).fill()
        } else if isPredicted {
            NSColor(hex: 0xFF7A94, alpha: 0.16).setFill()
            NSBezierPath(ovalIn: circle).fill()
            NSColor(hex: 0xFF7A94, alpha: 0.55).setStroke()
            let p = NSBezierPath(ovalIn: circle)
            p.lineWidth = 1.2
            p.setLineDash([3, 2.5], count: 2, phase: 0)
            p.stroke()
        }

        if isToday && !isPeriod {
            NSColor.labelColor.withAlphaComponent(0.55).setStroke()
            let p = NSBezierPath(ovalIn: circle.insetBy(dx: 1, dy: 1))
            p.lineWidth = 1.4
            p.stroke()
        }

        var color: NSColor = .labelColor
        var weight: NSFont.Weight = .regular
        if isPeriod { color = .white; weight = .bold }
        else if !inMonth { color = .tertiaryLabelColor }
        else if isFuture { color = .tertiaryLabelColor }
        else if isPredicted { color = NSColor(hex: 0xE4606F) }

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: weight),
            .foregroundColor: color
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(at: CGPoint(x: cx - size.width / 2, y: cy - size.height / 2), withAttributes: attrs)

        if isOvulation {
            NSColor(hex: 0x9B8CFF).setFill()
            NSBezierPath(ovalIn: CGRect(x: cx - 3, y: cy + s / 2 - 1, width: 6, height: 6)).fill()
        }
    }
}

// MARK: - 日历窗口

final class CalendarController: NSWindowController {
    private var monthAnchor = Date()
    private var cells: [DayCell] = []
    private let monthLabel = NSTextField(labelWithString: "")
    private let statsLabel = NSTextField(labelWithString: "")
    private let cycleStepper = NSStepper()
    private let periodStepper = NSStepper()
    private let cycleValue = NSTextField(labelWithString: "")
    private let periodValue = NSTextField(labelWithString: "")
    private var onChanged: (() -> Void)?

    convenience init(onChanged: @escaping () -> Void) {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 620),
                           styleMask: [.titled, .closable, .miniaturizable],
                           backing: .buffered, defer: false)
        win.title = "月伴 · 经期日历"
        win.titlebarAppearsTransparent = true
        self.init(window: win)
        self.onChanged = onChanged
        buildUI()
        reload()
    }

    private func makeButton(_ title: String, action: Selector) -> NSButton {
        let b = NSButton(frame: .zero)
        b.title = title
        b.bezelStyle = .roundRect
        b.font = NSFont.systemFont(ofSize: 13)
        b.target = self
        b.action = action
        return b
    }

    private func makeLabel(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular,
                           color: NSColor = .labelColor) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = NSFont.systemFont(ofSize: size, weight: weight)
        l.textColor = color
        l.isBezeled = false
        l.drawsBackground = false
        l.isEditable = false
        l.isSelectable = false
        return l
    }

    private func buildUI() {
        guard let win = window, let root = win.contentView else { return }
        root.wantsLayer = true
        let container = FlippedView(frame: root.bounds)
        container.autoresizingMask = [.width, .height]
        container.wantsLayer = true
        root.addSubview(container)

        monthLabel.font = NSFont.systemFont(ofSize: 16, weight: .semibold)
        monthLabel.frame = NSRect(x: 100, y: 14, width: 200, height: 26)
        monthLabel.alignment = .center
        container.addSubview(monthLabel)

        let prev = makeButton("‹", action: #selector(prevMonth))
        prev.frame = NSRect(x: 24, y: 12, width: 34, height: 28)
        container.addSubview(prev)
        let next = makeButton("›", action: #selector(nextMonth))
        next.frame = NSRect(x: 62, y: 12, width: 34, height: 28)
        container.addSubview(next)
        let today = makeButton("今天", action: #selector(gotoToday))
        today.frame = NSRect(x: 306, y: 12, width: 70, height: 28)
        container.addSubview(today)

        let names = ["一", "二", "三", "四", "五", "六", "日"]
        for (i, n) in names.enumerated() {
            let l = makeLabel(n, size: 12, weight: .medium, color: .secondaryLabelColor)
            l.alignment = .center
            l.frame = NSRect(x: 24 + CGFloat(i) * 50.3, y: 50, width: 50.3, height: 20)
            container.addSubview(l)
        }

        for r in 0..<6 {
            for c in 0..<7 {
                let cell = DayCell(frame: NSRect(x: 24 + CGFloat(c) * 50.3, y: 74 + CGFloat(r) * 46, width: 50.3, height: 46))
                cell.onToggle = { [weak self] d in
                    Engine.shared.toggle(d)
                    self?.reload()
                    self?.onChanged?()
                }
                container.addSubview(cell)
                cells.append(cell)
            }
        }

        let legend = makeLabel("● 已记录经期    ○ 预测经期    ● 预测排卵日    ○ 今天", size: 11.5, color: .tertiaryLabelColor)
        legend.frame = NSRect(x: 24, y: 356, width: 352, height: 18)
        container.addSubview(legend)

        statsLabel.font = NSFont.systemFont(ofSize: 12.5)
        statsLabel.textColor = .secondaryLabelColor
        statsLabel.frame = NSRect(x: 24, y: 382, width: 258, height: 54)
        statsLabel.lineBreakMode = .byWordWrapping
        statsLabel.maximumNumberOfLines = 3
        container.addSubview(statsLabel)

        let clear = makeButton("清空记录", action: #selector(clearAll))
        clear.frame = NSRect(x: 290, y: 386, width: 86, height: 26)
        container.addSubview(clear)

        let sep = NSBox(frame: NSRect(x: 24, y: 448, width: 352, height: 1))
        sep.boxType = .separator
        container.addSubview(sep)

        let pTitle = makeLabel("没有足够记录时的预设", size: 12.5, weight: .medium)
        pTitle.frame = NSRect(x: 24, y: 460, width: 200, height: 18)
        container.addSubview(pTitle)

        let cLabel = makeLabel("平均周期", size: 12.5, color: .secondaryLabelColor)
        cLabel.frame = NSRect(x: 24, y: 488, width: 90, height: 20)
        container.addSubview(cLabel)
        cycleValue.font = NSFont.systemFont(ofSize: 12.5, weight: .medium)
        cycleValue.frame = NSRect(x: 110, y: 488, width: 60, height: 20)
        container.addSubview(cycleValue)
        cycleStepper.frame = NSRect(x: 176, y: 485, width: 20, height: 26)
        cycleStepper.minValue = 18
        cycleStepper.maxValue = 60
        cycleStepper.increment = 1
        cycleStepper.target = self
        cycleStepper.action = #selector(cycleChanged(_:))
        container.addSubview(cycleStepper)

        let pLabel = makeLabel("行经天数", size: 12.5, color: .secondaryLabelColor)
        pLabel.frame = NSRect(x: 226, y: 488, width: 90, height: 20)
        container.addSubview(pLabel)
        periodValue.font = NSFont.systemFont(ofSize: 12.5, weight: .medium)
        periodValue.frame = NSRect(x: 306, y: 488, width: 40, height: 20)
        container.addSubview(periodValue)
        periodStepper.frame = NSRect(x: 346, y: 485, width: 20, height: 26)
        periodStepper.minValue = 2
        periodStepper.maxValue = 10
        periodStepper.increment = 1
        periodStepper.target = self
        periodStepper.action = #selector(periodChanged(_:))
        container.addSubview(periodStepper)

        let hint = makeLabel("点一下日期 = 标记「这天来月经了」，再点取消。数据只存在你自己的电脑里。",
                             size: 11, color: .tertiaryLabelColor)
        hint.frame = NSRect(x: 24, y: 526, width: 352, height: 34)
        hint.lineBreakMode = .byWordWrapping
        hint.maximumNumberOfLines = 2
        container.addSubview(hint)
    }

    @objc private func prevMonth() {
        monthAnchor = addDays(monthAnchor, -30)
        monthAnchor = firstOfMonth(monthAnchor)
        reload()
    }

    @objc private func nextMonth() {
        monthAnchor = addDays(firstOfMonth(monthAnchor), 32)
        monthAnchor = firstOfMonth(monthAnchor)
        reload()
    }

    @objc private func gotoToday() {
        monthAnchor = firstOfMonth(Date())
        reload()
    }

    private func firstOfMonth(_ d: Date) -> Date {
        let c = Calendar.current.dateComponents([.year, .month], from: d)
        return Calendar.current.date(from: c) ?? d
    }

    @objc private func clearAll() {
        let alert = NSAlert()
        alert.messageText = "清空所有经期记录？"
        alert.informativeText = "这个操作不可撤销。"
        alert.addButton(withTitle: "清空")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            Engine.shared.data.marked = []
            reload()
            onChanged?()
        }
    }

    @objc private func cycleChanged(_ s: NSStepper) {
        Engine.shared.data.presetCycle = Int(s.integerValue)
        reload()
        onChanged?()
    }

    @objc private func periodChanged(_ s: NSStepper) {
        Engine.shared.data.presetPeriod = Int(s.integerValue)
        reload()
        onChanged?()
    }

    func reload() {
        let engine = Engine.shared
        let cal = Calendar.current
        let first = firstOfMonth(monthAnchor)
        let comps = cal.dateComponents([.year, .month], from: first)
        monthLabel.stringValue = "\(comps.year ?? 0) 年 \(comps.month ?? 0) 月"

        let weekday = cal.component(.weekday, from: first)   // 1 = 周日
        let leading = (weekday + 5) % 7                      // 周一开头
        let gridStart = addDays(first, -leading)

        let predicted = engine.predictedDays()
        let ovulations = engine.predictedOvulationDays()
        let today = midnight(Date())
        let marked = engine.data.marked

        for (i, cell) in cells.enumerated() {
            let d = addDays(gridStart, i)
            let k = dayKey(d)
            cell.date = d
            cell.inMonth = (cal.component(.month, from: d) == comps.month && cal.component(.year, from: d) == comps.year)
            cell.isPeriod = marked.contains(k)
            cell.isPredicted = predicted.contains(k) && !cell.isPeriod
            cell.isOvulation = ovulations.contains(k) && !cell.isPeriod
            cell.isToday = (dayGap(d, today) == 0)
            cell.isFuture = d > today
            cell.needsDisplay = true
        }

        let rs = engine.runs()
        let st = engine.status()
        if rs.isEmpty {
            statsLabel.stringValue = "已记录 0 次 · 用上面的预设值预测：周期 \(st.cycleLen) 天，行经 \(st.periodLen) 天"
        } else {
            statsLabel.stringValue = "已记录 \(rs.count) 次 · 平均周期 \(st.cycleLen) 天 · 平均行经 \(engine.avgPeriod) 天\n"
                + "上次开始 \(dayKey(rs.last!.start)) · 预测下次 \(dayKey(st.nextStart))"
        }

        cycleStepper.integerValue = engine.data.presetCycle
        periodStepper.integerValue = engine.data.presetPeriod
        cycleValue.stringValue = "\(engine.data.presetCycle) 天"
        periodValue.stringValue = "\(engine.data.presetPeriod) 天"
    }

    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var petWindow: PetWindow!
    private var calController: CalendarController?
    private var timer: Timer?
    private var locked = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        petWindow = PetWindow()
        let fallbackOrigin: NSPoint = {
            guard let screen = NSScreen.main ?? NSScreen.screens.first else { return NSPoint(x: 120, y: 260) }
            let f = screen.visibleFrame
            return NSPoint(x: f.minX + 48, y: f.minY + 160)
        }()
        if let ox = Engine.shared.data.originX, let oy = Engine.shared.data.originY {
            petWindow.setFrameOrigin(NSPoint(x: ox, y: oy))
        } else {
            petWindow.setFrameOrigin(fallbackOrigin)
        }
        // 若保存的位置已不在任何屏幕内（例如拔掉外接显示器），拉回主屏
        if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(petWindow.frame) }) {
            petWindow.setFrameOrigin(fallbackOrigin)
        }
        petWindow.root.onDoubleClick = { [weak self] in self?.openCalendar(nil) }
        petWindow.root.menu = contextMenu()
        petWindow.petView.avatar = AvatarStore.shared.image   // 有自定义形象就用它
        petWindow.orderFrontRegardless()

        NotificationCenter.default.addObserver(self,
                                               selector: #selector(windowMoved(_:)),
                                               name: NSWindow.didMoveNotification,
                                               object: petWindow)

        setupStatusItem()
        refresh()

        let t = Timer(timeInterval: 60, target: self, selector: #selector(refreshTick), userInfo: nil, repeats: true)
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let img = NSImage(systemSymbolName: "drop.fill", accessibilityDescription: "月伴") {
            img.isTemplate = true
            statusItem.button?.image = img
        } else {
            statusItem.button?.title = "月伴"
        }
        buildMenu()
    }

    private func buildMenu() {
        let st = Engine.shared.status()
        let menu = NSMenu()

        let head = NSMenuItem(title: "今日：\(st.phase.title) · \(st.countdown)", action: nil, keyEquivalent: "")
        head.isEnabled = false
        menu.addItem(head)
        menu.addItem(NSMenuItem.separator())

        let cal = NSMenuItem(title: "打开日历…", action: #selector(openCalendar(_:)), keyEquivalent: "")
        cal.target = self
        menu.addItem(cal)

        let today = midnight(Date())
        let mark = NSMenuItem(title: Engine.shared.isMarked(today) ? "取消记录今天" : "记录今天来月经",
                              action: #selector(toggleToday(_:)), keyEquivalent: "")
        mark.target = self
        menu.addItem(mark)

        let lock = NSMenuItem(title: locked ? "解锁位置" : "锁定位置（防误拖）",
                              action: #selector(toggleLock(_:)), keyEquivalent: "")
        lock.target = self
        menu.addItem(lock)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(avatarItem())
        let reset = NSMenuItem(title: "恢复默认形象（Hello Kitty）",
                               action: #selector(resetAvatar(_:)), keyEquivalent: "")
        reset.target = self
        reset.isEnabled = AvatarStore.shared.hasCustom
        menu.addItem(reset)

        menu.addItem(NSMenuItem.separator())
        let about = NSMenuItem(title: "关于月伴", action: #selector(about(_:)), keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        let quit = NSMenuItem(title: "退出", action: #selector(quit(_:)), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    private func avatarItem() -> NSMenuItem {
        let item = NSMenuItem(title: AvatarStore.shared.hasCustom ? "换个形象…" : "自定义形象…（用照片）",
                              action: #selector(customizeAvatar(_:)), keyEquivalent: "")
        item.target = self
        return item
    }

    private func contextMenu() -> NSMenu {
        let menu = NSMenu()
        let cal = NSMenuItem(title: "打开日历…", action: #selector(openCalendar(_:)), keyEquivalent: "")
        cal.target = self
        menu.addItem(cal)
        let mark = NSMenuItem(title: "记录今天来月经", action: #selector(toggleToday(_:)), keyEquivalent: "")
        mark.target = self
        menu.addItem(mark)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(avatarItem())
        if AvatarStore.shared.hasCustom {
            let reset = NSMenuItem(title: "恢复默认形象", action: #selector(resetAvatar(_:)), keyEquivalent: "")
            reset.target = self
            menu.addItem(reset)
        }
        menu.addItem(NSMenuItem.separator())
        let quit = NSMenuItem(title: "退出", action: #selector(quit(_:)), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    /// 气泡上闪一句提示，几秒后自动还原
    private func flash(_ text: String) {
        let old = petWindow.bubble.foot
        petWindow.bubble.foot = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) { [weak self] in
            guard let self = self else { return }
            self.petWindow.bubble.foot = old
        }
    }

    @objc private func customizeAvatar(_ sender: Any?) {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.message = "选一张照片，我把主体抠出来做成你的桌宠。照片只在这台电脑上处理，不会上传。"
        panel.prompt = "做成桌宠"
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        switch AvatarStore.shared.make(from: url) {
        case .ok(let img):
            petWindow.petView.avatar = img
            flash("新形象好啦 ✨")
        case .failed(let msg):
            let a = NSAlert()
            a.alertStyle = .warning
            a.messageText = "这个形象没做成"
            a.informativeText = msg
            a.addButton(withTitle: "知道了")
            a.runModal()
        }
    }

    @objc private func resetAvatar(_ sender: Any?) {
        AvatarStore.shared.clear()
        petWindow.petView.avatar = nil
        flash("已换回 Hello Kitty")
    }

    @objc private func refreshTick() { refresh() }

    func refresh() {
        let st = Engine.shared.status()
        petWindow.update(st)
        buildMenu()
        petWindow.root.menu = contextMenu()   // 让「恢复默认形象」随状态出现/消失
        calController?.reload()
    }

    @objc private func openCalendar(_ sender: Any?) {
        if calController == nil {
            calController = CalendarController(onChanged: { [weak self] in self?.refresh() })
            calController?.window?.center()
        }
        calController?.show()
    }

    @objc private func toggleToday(_ sender: Any?) {
        Engine.shared.toggle(midnight(Date()))
        refresh()
    }

    @objc private func toggleLock(_ sender: Any?) {
        locked.toggle()
        petWindow.root.dragEnabled = !locked
        buildMenu()
    }

    @objc private func about(_ sender: Any?) {
        let a = NSAlert()
        a.messageText = "月伴 · 经期小桌宠"
        a.informativeText = """
        双击小家伙 → 打开日历
        点日期 → 标记「这天来月经了」
        拖动 → 换个位置待着
        右键 → 快捷菜单

        数据只保存在本机：
        ~/Library/Application Support/Yueban/data.json

        预测基于你自己的历史记录，仅供参考，别当医疗建议。
        """
        a.addButton(withTitle: "好")
        a.runModal()
    }

    @objc private func quit(_ sender: Any?) {
        NSApp.terminate(nil)
    }

    @objc private func windowMoved(_ n: Notification) {
        let o = petWindow.frame.origin
        Engine.shared.data.originX = Double(o.x)
        Engine.shared.data.originY = Double(o.y)
    }
}

// MARK: - 离线自检渲染（只在设置了 YUEBAN_SNAPSHOT 时执行）

func renderSnapshots(to dir: String) {
    func snapshot(_ view: NSView, size: NSSize, name: String) {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]),
              let raw = NSImage(data: png) else { return }
        let out = NSImage(size: size)
        out.lockFocus()
        NSColor(hex: 0xF2F2F4).setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
        raw.draw(in: NSRect(origin: .zero, size: size))
        out.unlockFocus()
        if let tiff = out.tiffRepresentation,
           let rep2 = NSBitmapImageRep(data: tiff),
           let png2 = rep2.representation(using: .png, properties: [:]) {
            try? png2.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
        }
    }

    let cases: [Phase] = [.menstrual, .follicular, .ovulation, .luteal, .none]
    for ph in cases {
        let root = FlippedView(frame: NSRect(x: 0, y: 0, width: 344, height: 152))
        let pet = PetView(frame: NSRect(x: 0, y: 0, width: 108, height: 152))
        pet.phase = ph
        let bub = BubbleView(frame: NSRect(x: 100, y: 18, width: 240, height: 100))
        bub.dotColor = ph.color
        bub.title = ph.title + (ph == .none ? "" : " · 第 12 天")
        bub.tip = ph.tip
        bub.foot = ph == .none ? "还没有记录" : "距下次经期还有 12 天"
        root.addSubview(pet)
        root.addSubview(bub)
        snapshot(root, size: NSSize(width: 344, height: 152), name: "pet_\(ph.rawValue)")
    }

    // 自定义形象调试：YUEBAN_TEST_PHOTO=<图片路径> 时渲染一张带照片形象的图
    if let photo = ProcessInfo.processInfo.environment["YUEBAN_TEST_PHOTO"] {
        let out = ProcessInfo.processInfo.environment["YUEBAN_TEST_AVATAR_OUT"].map { URL(fileURLWithPath: $0) }
        switch AvatarStore.shared.make(from: URL(fileURLWithPath: photo), saveTo: out) {
        case .ok(let img):
            let root = FlippedView(frame: NSRect(x: 0, y: 0, width: 344, height: 152))
            let pet = PetView(frame: NSRect(x: 0, y: 0, width: 108, height: 152))
            pet.phase = .follicular
            pet.avatar = img
            let bub = BubbleView(frame: NSRect(x: 100, y: 18, width: 240, height: 100))
            bub.dotColor = Phase.follicular.color
            bub.title = "卵泡期 · 第 8 天"
            bub.tip = Phase.follicular.tip
            bub.foot = "距下次经期还有 18 天"
            root.addSubview(pet)
            root.addSubview(bub)
            snapshot(root, size: NSSize(width: 344, height: 152), name: "pet_avatar")
            print("avatar ok, size=\(img.size)")
        case .failed(let m):
            print("avatar failed: \(m)")
        }
    }

    let big = FlippedView(frame: NSRect(x: 0, y: 0, width: 432, height: 608))
    let bigPet = PetView(frame: NSRect(x: 0, y: 0, width: 432, height: 608))
    bigPet.phase = .menstrual
    big.addSubview(bigPet)
    // 日历
    let cal = CalendarController(onChanged: {})
    if let cv = cal.window?.contentView {
        cv.layoutSubtreeIfNeeded()
        snapshot(cv, size: cv.bounds.size, name: "calendar")
    }
    print("snapshots written to \(dir)")

    // App 图标
    if let iconPath = ProcessInfo.processInfo.environment["YUEBAN_ICON"] {
        let root = IconCanvasView(frame: NSRect(x: 0, y: 0, width: 1024, height: 1024))
        let pet = PetView(frame: NSRect(x: 192, y: 70, width: 640, height: 890))
        pet.phase = .menstrual
        pet.awake = true
        root.addSubview(pet)
        root.layoutSubtreeIfNeeded()
        if let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB,
                                      bytesPerRow: 0, bitsPerPixel: 0) {
            root.cacheDisplay(in: root.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: iconPath))
                print("icon written to \(iconPath)")
            }
        }
    }
}

let app = NSApplication.shared
if let dir = ProcessInfo.processInfo.environment["YUEBAN_SNAPSHOT"] {
    app.setActivationPolicy(.accessory)
    renderSnapshots(to: dir)
} else {
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
