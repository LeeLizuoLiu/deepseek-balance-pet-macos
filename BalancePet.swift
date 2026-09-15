// BalancePet.swift — DeepSeek 余额桌宠（macOS 原生版）
//
// deepseek-balance-pet 的原生 macOS 对应物：不再依赖 Windows / WPF /
// DesktopPet.exe，也不再依赖浏览器标签页。它是一个无边框、背景透明、
// 始终置顶的 NSWindow，浮在所有窗口与所有桌面空间之上，全屏 App 上也可见。
//
// 与网页挂件共用同一张人物立绘与同一套气泡几何（960×912 图上的
// (70,130)-(475,170)），因此观感一致。
//
// 构建：  ./build.sh
// 自检：  ./build/DeepSeekBalancePet.app/Contents/MacOS/DeepSeekBalancePet --selftest

import Cocoa

// MARK: - 立绘几何（与网页版 / 原 WPF 版一致，左上角为原点）

private let ART_WIDTH: CGFloat = 960
private let ART_HEIGHT: CGFloat = 912
private let BUBBLE_X: CGFloat = 70
private let BUBBLE_Y: CGFloat = 130
private let BUBBLE_W: CGFloat = 475
private let BUBBLE_H: CGFloat = 170

private let POLL_MIN_SECONDS: Double = 5
private let BALANCE_CACHE_SECONDS: Double = 8
private let REQUEST_TIMEOUT_SECONDS: Double = 15

// MARK: - 路径

private enum Paths {
    static let supportDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("DeepSeekBalancePet", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    static var configFile: URL { supportDir.appendingPathComponent("config.json") }
    static var logFile: URL { supportDir.appendingPathComponent("pet.log") }
    static var credentialsFile: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".dsh/.credentials.yaml")
    }
}

// MARK: - 日志

private enum Log {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    static func write(_ message: String) {
        let line = "[\(formatter.string(from: Date()))] \(message)\n"
        FileHandle.standardError.write(Data(line.utf8))
        guard let data = Data(line.utf8) as Data? else { return }
        if let handle = try? FileHandle(forWritingTo: Paths.logFile) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: Paths.logFile, options: .atomic)
        }
    }
}

// MARK: - 配置

/// 全部字段都可选：config.json 里写哪一项就覆盖哪一项，其余用默认值。
private struct PetConfig: Decodable {
    var pollSeconds: Double = 20
    var width: Double = 220
    var currency: String = "CNY"
    var shadow: Bool = true
    var animation: Bool = true
    var margin: Double = 16
    var apiBase: String = "https://api.deepseek.com"

    private enum CodingKeys: String, CodingKey {
        case pollSeconds, width, currency, shadow, animation, margin, apiBase
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = PetConfig()
        pollSeconds = try c.decodeIfPresent(Double.self, forKey: .pollSeconds) ?? defaults.pollSeconds
        width = try c.decodeIfPresent(Double.self, forKey: .width) ?? defaults.width
        currency = try c.decodeIfPresent(String.self, forKey: .currency) ?? defaults.currency
        shadow = try c.decodeIfPresent(Bool.self, forKey: .shadow) ?? defaults.shadow
        animation = try c.decodeIfPresent(Bool.self, forKey: .animation) ?? defaults.animation
        margin = try c.decodeIfPresent(Double.self, forKey: .margin) ?? defaults.margin
        apiBase = try c.decodeIfPresent(String.self, forKey: .apiBase) ?? defaults.apiBase
    }

    static func load() -> PetConfig {
        guard let data = try? Data(contentsOf: Paths.configFile) else { return PetConfig() }
        do {
            let config = try JSONDecoder().decode(PetConfig.self, from: data)
            Log.write("config loaded from \(Paths.configFile.path)")
            return config
        } catch {
            Log.write("config.json is unreadable (\(error.localizedDescription)); using defaults")
            return PetConfig()
        }
    }

    /// 写一份带注释说明的模板，方便用户改。
    static func writeTemplateIfMissing() {
        guard !FileManager.default.fileExists(atPath: Paths.configFile.path) else { return }
        let template = """
        {
          "pollSeconds": 20,
          "width": 220,
          "currency": "CNY",
          "shadow": true,
          "animation": true,
          "margin": 16,
          "apiBase": "https://api.deepseek.com"
        }
        """
        try? template.write(to: Paths.configFile, atomically: true, encoding: .utf8)
    }
}

// MARK: - 余额

private struct BalanceInfo {
    let currency: String
    let total: String
    let granted: String
    let toppedUp: String
}

private struct BalanceSnapshot {
    let available: Bool
    let infos: [BalanceInfo]
    let chosen: BalanceInfo
}

private enum BalanceError: LocalizedError {
    case noCredentials(String)
    case http(Int)
    case malformed(String)

    var errorDescription: String? {
        switch self {
        case .noCredentials(let detail): return "找不到 DEEPSEEK_API_KEY（\(detail)）"
        case .http(let code): return "余额接口返回 HTTP \(code)"
        case .malformed(let detail): return "余额接口返回内容无法解析：\(detail)"
        }
    }
}

private func symbolFor(_ currency: String) -> String {
    switch currency.uppercased() {
    case "CNY": return "¥"
    case "USD": return "$"
    case "EUR": return "€"
    case "HKD": return "HK$"
    default: return ""
    }
}

/// 读取 API Key：优先环境变量，其次 ~/.dsh/.credentials.yaml（与原插件一致）。
private func readApiKey() throws -> String {
    if let env = ProcessInfo.processInfo.environment["DEEPSEEK_API_KEY"],
       !env.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return env.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    let path = Paths.credentialsFile.path
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
        throw BalanceError.noCredentials("无法读取 \(path)")
    }
    let pattern = "(?m)^\\s*DEEPSEEK_API_KEY\\s*:\\s*(.+?)\\s*$"
    guard let regex = try? NSRegularExpression(pattern: pattern) else {
        throw BalanceError.noCredentials("内置正则无效")
    }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    guard let match = regex.firstMatch(in: text, range: range),
          let keyRange = Range(match.range(at: 1), in: text) else {
        throw BalanceError.noCredentials("\(path) 中没有 DEEPSEEK_API_KEY 行")
    }
    var key = String(text[keyRange])
    if key.count >= 2, (key.hasPrefix("\"") && key.hasSuffix("\"")) || (key.hasPrefix("'") && key.hasSuffix("'")) {
        key = String(key.dropFirst().dropLast())
    }
    guard !key.isEmpty else { throw BalanceError.noCredentials("\(path) 中的 key 为空") }
    return key
}

/// 多币种账号里挑一条：优先指定币种，其次第一个非零，最后第一条。
/// （原 Windows 版直接取 [0]，在 [USD:0.00, CNY:48.94] 这种账号上会显示 $0.00。）
private func pickInfo(_ infos: [BalanceInfo], currency: String) -> BalanceInfo? {
    let wanted = currency.trimmingCharacters(in: .whitespaces).uppercased()
    if !wanted.isEmpty, wanted != "AUTO",
       let exact = infos.first(where: { $0.currency.uppercased() == wanted }) {
        return exact
    }
    if let funded = infos.first(where: { (Double($0.total) ?? 0) != 0 }) { return funded }
    return infos.first
}

private final class BalanceClient {
    private let config: PetConfig
    private var cache: BalanceSnapshot?
    private var cacheAt = Date.distantPast

    init(config: PetConfig) { self.config = config }

    /// `onMain` 为 false 时回调留在 URLSession 的队列上——无窗口自检阻塞等待时用。
    func read(force: Bool, onMain: Bool = true, completion: @escaping (Result<BalanceSnapshot, Error>) -> Void) {
        if !force, let cached = cache, Date().timeIntervalSince(cacheAt) < BALANCE_CACHE_SECONDS {
            completion(.success(cached))
            return
        }

        let key: String
        do { key = try readApiKey() } catch {
            completion(.failure(error))
            return
        }

        let base = config.apiBase.hasSuffix("/") ? String(config.apiBase.dropLast()) : config.apiBase
        guard let url = URL(string: base + "/user/balance") else {
            completion(.failure(BalanceError.malformed("apiBase 不是合法 URL")))
            return
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = REQUEST_TIMEOUT_SECONDS
        request.cachePolicy = .reloadIgnoringLocalCacheData

        URLSession.shared.dataTask(with: request) { [config, onMain] data, response, error in
            let finish: () -> Void = {
                if let error = error {
                    completion(.failure(error))
                    return
                }
                guard let http = response as? HTTPURLResponse else {
                    completion(.failure(BalanceError.http(-1)))
                    return
                }
                guard http.statusCode == 200 else {
                    completion(.failure(BalanceError.http(http.statusCode)))
                    return
                }
                guard let data = data else {
                    completion(.failure(BalanceError.malformed("空响应")))
                    return
                }
                guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    completion(.failure(BalanceError.malformed("不是 JSON 对象")))
                    return
                }
                let rawInfos = (root["balance_infos"] as? [[String: Any]]) ?? []
                let infos = rawInfos.map {
                    BalanceInfo(currency: $0["currency"] as? String ?? "",
                                total: $0["total_balance"] as? String ?? "",
                                granted: $0["granted_balance"] as? String ?? "",
                                toppedUp: $0["topped_up_balance"] as? String ?? "")
                }
                guard let chosen = pickInfo(infos, currency: config.currency) else {
                    completion(.failure(BalanceError.malformed("balance_infos 为空")))
                    return
                }
                completion(.success(BalanceSnapshot(available: (root["is_available"] as? Bool) ?? false,
                                                    infos: infos, chosen: chosen)))
            }
            if onMain { DispatchQueue.main.async(execute: finish) } else { finish() }
        }.resume()
    }
    func invalidate() { cache = nil; cacheAt = .distantPast }
}

private func formatTotal(_ value: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty, let number = Double(trimmed) else { return trimmed }
    return String(format: "%.2f", number)
}

// MARK: - 立绘

private struct Artwork {
    let image: CGImage
    /// 烘进图片的投影留白（阴影关闭时为 0）。
    let pad: CGFloat
    var pixelWidth: CGFloat { ART_WIDTH + pad * 2 }
    var pixelHeight: CGFloat { ART_HEIGHT + pad * 2 }
}

private func loadArtwork(shadow: Bool) -> Artwork? {
    var candidates: [URL] = []
    if let override = ProcessInfo.processInfo.environment["PET_PNG"], !override.isEmpty {
        candidates.append(URL(fileURLWithPath: override))
    }
    if let bundled = Bundle.main.url(forResource: "pet", withExtension: "png") {
        candidates.append(bundled)
    }

    guard let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }),
          let source = NSImage(contentsOf: url),
          source.size.width > 0, source.size.height > 0 else {
        Log.write("pet.png not found; looked in \(candidates.map(\.path))")
        return nil
    }

    // 投影用 NSShadow 烘进图片，效果对齐原版 WPF 的 DropShadowEffect(14 / 3 / 0.38)。
    let pad: CGFloat = shadow ? 24 : 0
    if !shadow, let cg = source.cgImage(forProposedRect: nil, context: nil, hints: nil) {
        return Artwork(image: cg, pad: 0)
    }

    let size = NSSize(width: source.size.width + pad * 2, height: source.size.height + pad * 2)
    let canvas = NSImage(size: size)
    canvas.lockFocus()
    let shadowEffect = NSShadow()
    shadowEffect.shadowBlurRadius = 14
    shadowEffect.shadowOffset = NSSize(width: 0, height: -3)
    shadowEffect.shadowColor = NSColor.black.withAlphaComponent(0.38)
    shadowEffect.set()
    source.draw(in: NSRect(x: pad, y: pad, width: source.size.width, height: source.size.height),
                from: .zero, operation: .sourceOver, fraction: 1)
    canvas.unlockFocus()
    guard let cg = canvas.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
    return Artwork(image: cg, pad: pad)
}

// MARK: - 窗口

/// 无边框透明窗口，永不抢焦点（canBecomeKey 恒为 false）。
private final class PetWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// 人物视图：画立绘、托气泡文字、处理拖动/单击/右键/悬停。
private final class PetView: NSView {
    var onDrag: ((NSPoint) -> Void)?
    var onDragEnd: (() -> Void)?
    var onClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    var onHideRequest: (() -> Void)?
    var onContextMenu: ((NSPoint) -> Void)?

    private let artHost = NSView(frame: .zero)
    private let label = NSTextField(labelWithString: "")
    private var bubbleBox = NSRect.zero
    private var hideButtonRect = NSRect.zero
    private var hovering = false
    private var pressOrigin: NSPoint = .zero
    private var windowOriginAtPress: NSPoint = .zero
    private var didMove = false

    func configure(artwork: Artwork, bubbleRect: NSRect, size: NSSize) {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        artHost.frame = NSRect(origin: .zero, size: size)
        artHost.wantsLayer = true
        artHost.layer?.backgroundColor = NSColor.clear.cgColor
        artHost.layer?.contents = artwork.image
        artHost.layer?.contentsGravity = .resize
        artHost.layer?.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        addSubview(artHost)

        label.isBezeled = false
        label.drawsBackground = false
        label.isEditable = false
        label.isSelectable = false
        label.alignment = .center
        label.maximumNumberOfLines = 1
        label.cell?.lineBreakMode = .byClipping
        label.cell?.wraps = false
        label.cell?.usesSingleLineMode = true
        label.cell?.truncatesLastVisibleLine = false
        bubbleBox = bubbleRect
        label.frame = bubbleRect
        artHost.addSubview(label)

        hideButtonRect = NSRect(x: size.width - 20, y: size.height - 20, width: 18, height: 18)
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    /// 气泡文字，自动缩字号以单行放下（与 WPF / 网页版同一算法）。
    func setBubbleText(_ text: String, color: NSColor) {
        let boxW = bubbleBox.width
        let boxH = bubbleBox.height
        var size = max(11, min(30, boxH * 0.62))
        var font = NSFont.boldSystemFont(ofSize: size)
        var width = (text as NSString).size(withAttributes: [.font: font]).width
        var guardCount = 60
        while width > boxW && size > 8 && guardCount > 0 {
            size -= 1
            font = NSFont.boldSystemFont(ofSize: size)
            width = (text as NSString).size(withAttributes: [.font: font]).width
            guardCount -= 1
        }
        // 单行标签按自身行高在气泡框内垂直居中（NSTextField 不会自动居中）。
        let lineHeight = ceil(font.ascender - font.descender + font.leading) + 2
        label.font = font
        label.textColor = color
        label.stringValue = text
        label.frame = NSRect(x: bubbleBox.minX,
                             y: bubbleBox.minY + (boxH - lineHeight) / 2,
                             width: boxW,
                             height: lineHeight)
        needsDisplay = true
    }

    // 悬停时的 × 按钮、拖动中的视觉反馈
    override func draw(_ dirtyRect: NSRect) {
        guard hovering else { return }
        let circle = NSBezierPath(ovalIn: hideButtonRect)
        NSColor(calibratedWhite: 0.1, alpha: 0.72).setFill()
        circle.fill()
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 11),
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph
        ]
        let glyph = "×" as NSString
        let glyphSize = glyph.size(withAttributes: attrs)
        glyph.draw(in: NSRect(x: hideButtonRect.midX - glyphSize.width / 2,
                              y: hideButtonRect.midY - glyphSize.height / 2,
                              width: glyphSize.width, height: glyphSize.height),
                   withAttributes: attrs)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if hovering && hideButtonRect.contains(point) {
            onHideRequest?()
            return
        }
        didMove = false
        pressOrigin = NSEvent.mouseLocation
        windowOriginAtPress = window?.frame.origin ?? .zero
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window = window else { return }
        let current = NSEvent.mouseLocation
        let dx = current.x - pressOrigin.x
        let dy = current.y - pressOrigin.y
        if abs(dx) > 3 || abs(dy) > 3 { didMove = true }
        guard didMove else { return }
        let target = NSPoint(x: windowOriginAtPress.x + dx, y: windowOriginAtPress.y + dy)
        window.setFrameOrigin(PetGeometry.clamp(origin: target, size: window.frame.size))
        onDrag?(window.frame.origin)
    }

    override func mouseUp(with event: NSEvent) {
        if didMove {
            onDragEnd?()
            return
        }
        if event.clickCount >= 2 { onDoubleClick?() } else { onClick?() }
    }

    override func rightMouseDown(with event: NSEvent) {
        onContextMenu?(convert(event.locationInWindow, from: nil))
    }

    /// 让气泡文字可被外部读取（自检/调试用）。
    var bubbleText: String { label.stringValue }
}

/// 隐藏后留下的小圆片，点一下恢复。
private final class ChipView: NSView {
    var onClick: (() -> Void)?
    var onContextMenu: ((NSPoint) -> Void)?

    override func draw(_ dirtyRect: NSRect) {
        let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1))
        NSColor(calibratedWhite: 0.1, alpha: 0.72).setFill()
        circle.fill()
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 14),
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph
        ]
        let glyph = "¥" as NSString
        let size = glyph.size(withAttributes: attrs)
        glyph.draw(in: NSRect(x: bounds.midX - size.width / 2,
                              y: bounds.midY - size.height / 2,
                              width: size.width, height: size.height),
                   withAttributes: attrs)
    }

    override func mouseDown(with event: NSEvent) { onClick?() }
    override func rightMouseDown(with event: NSEvent) {
        onContextMenu?(convert(event.locationInWindow, from: nil))
    }
}

/// 把窗口夹回它所在显示器的可视区域。
private enum PetGeometry {
    static func screen(containing frame: NSRect) -> NSScreen {
        let best = NSScreen.screens.max { lhs, rhs in
            lhs.frame.intersection(frame).area < rhs.frame.intersection(frame).area
        }
        return best ?? NSScreen.main ?? NSScreen.screens[0]
    }

    static func clamp(origin: NSPoint, size: NSSize) -> NSPoint {
        let visible = screen(containing: NSRect(origin: origin, size: size)).visibleFrame
        return NSPoint(x: min(max(origin.x, visible.minX), max(visible.minX, visible.maxX - size.width)),
                       y: min(max(origin.y, visible.minY), max(visible.minY, visible.maxY - size.height)))
    }
}

private extension NSRect {
    var area: CGFloat { isNull || isEmpty ? 0 : width * height }
}

// MARK: - 控制器

private final class PetController: NSObject {
    private let config = PetConfig.load()
    private lazy var client = BalanceClient(config: config)
    private var artwork: Artwork?

    private var petWindow: PetWindow!
    private var petView: PetView!
    private var chipWindow: PetWindow!
    private var chipView: ChipView!

    private var pollTimer: Timer?
    private var lastBalanceAt = Date.distantPast
    private var isHiddenByUser = false
    private var observers: [NSObjectProtocol] = []

    private var defaults: UserDefaults { .standard }

    func start() {
        guard let artwork = loadArtwork(shadow: config.shadow) else {
            Log.write("no artwork; aborting")
            NSApp.terminate(nil)
            return
        }
        self.artwork = artwork
        buildPetWindow(artwork: artwork)
        buildChipWindow()
        restoreState()
        startPolling()
        observeScreens()
        refresh(showPending: true)
        Log.write("pet ready (poll \(config.pollSeconds)s, width \(config.width)pt, currency \(config.currency))")
    }

    // MARK: 窗口搭建

    private func buildPetWindow(artwork: Artwork) {
        // 与网页版同义：config.width 指「人物本身」的宽度，投影留白额外算在外面。
        let scale = CGFloat(config.width) / ART_WIDTH
        let size = NSSize(width: (artwork.pixelWidth * scale).rounded(),
                          height: (artwork.pixelHeight * scale).rounded())

        petWindow = PetWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: .borderless, backing: .buffered, defer: false)
        petWindow.isOpaque = false
        petWindow.backgroundColor = .clear
        petWindow.hasShadow = false            // 投影已烘进图片
        petWindow.level = .floating
        petWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        petWindow.isMovableByWindowBackground = false
        petWindow.hidesOnDeactivate = false
        petWindow.isReleasedWhenClosed = false
        petWindow.animationBehavior = .none
        petWindow.ignoresMouseEvents = false

        // 气泡框：立绘坐标（左上原点）→ 视图坐标（左下原点），并把投影留白算进去。
        let bubble = NSRect(x: (BUBBLE_X + artwork.pad) * scale,
                            y: (artwork.pixelHeight - (BUBBLE_Y + artwork.pad + BUBBLE_H)) * scale,
                            width: BUBBLE_W * scale,
                            height: BUBBLE_H * scale)

        petView = PetView(frame: NSRect(origin: .zero, size: size))
        petView.configure(artwork: artwork, bubbleRect: bubble, size: size)
        petView.onDrag = { [weak self] _ in self?.syncChipPosition() }
        petView.onDragEnd = { [weak self] in self?.persistPosition() }
        petView.onClick = { [weak self] in self?.refresh(force: true, showPending: true) }
        petView.onDoubleClick = { [weak self] in self?.refresh(force: true, showPending: true) }
        petView.onHideRequest = { [weak self] in self?.setHidden(true) }
        petView.onContextMenu = { [weak self] point in self?.showMenu(in: self?.petView, at: point) }

        petWindow.contentView = petView

        if config.animation {
            let bob = CABasicAnimation(keyPath: "transform.translation.y")
            bob.fromValue = 0
            bob.toValue = -4
            bob.duration = 2.25
            bob.autoreverses = true
            bob.repeatCount = .infinity
            bob.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            petView.subviews.first?.layer?.add(bob, forKey: "bob")
        }
    }

    private func buildChipWindow() {
        let size = NSSize(width: 30, height: 30)
        chipWindow = PetWindow(contentRect: NSRect(origin: .zero, size: size),
                               styleMask: .borderless, backing: .buffered, defer: false)
        chipWindow.isOpaque = false
        chipWindow.backgroundColor = .clear
        chipWindow.hasShadow = true
        chipWindow.level = .floating
        chipWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        chipWindow.isReleasedWhenClosed = false
        chipWindow.animationBehavior = .none

        chipView = ChipView(frame: NSRect(origin: .zero, size: size))
        chipView.onClick = { [weak self] in
            self?.setHidden(false)
            self?.refresh(force: true, showPending: true)
        }
        chipView.onContextMenu = { [weak self] point in self?.showMenu(in: self?.chipView, at: point) }
        chipWindow.contentView = chipView
    }

    // MARK: 位置与显隐

    private func defaultOrigin(for size: NSSize) -> NSPoint {
        let visible = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        return NSPoint(x: visible.maxX - size.width - CGFloat(config.margin),
                       y: visible.minY + CGFloat(config.margin))
    }

    private func restoreState() {
        let storedX = defaults.object(forKey: "petX") as? Double
        let storedY = defaults.object(forKey: "petY") as? Double
        let size = petWindow.frame.size
        let origin: NSPoint
        if let x = storedX, let y = storedY {
            origin = PetGeometry.clamp(origin: NSPoint(x: x, y: y), size: size)
        } else {
            origin = PetGeometry.clamp(origin: defaultOrigin(for: size), size: size)
        }
        petWindow.setFrameOrigin(origin)
        syncChipPosition()

        isHiddenByUser = defaults.bool(forKey: "hidden")
        if isHiddenByUser {
            petWindow.orderOut(nil)
            chipWindow.orderFrontRegardless()
        } else {
            chipWindow.orderOut(nil)
            petWindow.orderFrontRegardless()
        }
    }

    private func syncChipPosition() {
        guard let petWindow = petWindow, let chipWindow = chipWindow else { return }
        let frame = petWindow.frame
        let target = NSPoint(x: frame.minX, y: frame.maxY - chipWindow.frame.height)
        chipWindow.setFrameOrigin(PetGeometry.clamp(origin: target, size: chipWindow.frame.size))
    }

    private func persistPosition() {
        let origin = petWindow.frame.origin
        defaults.set(Double(origin.x), forKey: "petX")
        defaults.set(Double(origin.y), forKey: "petY")
    }

    private func setHidden(_ hidden: Bool) {
        isHiddenByUser = hidden
        defaults.set(hidden, forKey: "hidden")
        if hidden {
            syncChipPosition()
            petWindow.orderOut(nil)
            chipWindow.orderFrontRegardless()
        } else {
            chipWindow.orderOut(nil)
            petWindow.orderFrontRegardless()
        }
    }

    // MARK: 菜单

    private func showMenu(in view: NSView?, at point: NSPoint) {
        guard let view = view else { return }
        let menu = NSMenu()
        let refreshItem = NSMenuItem(title: "立即刷新", action: #selector(menuRefresh), keyEquivalent: "")
        refreshItem.target = self
        menu.addItem(refreshItem)

        let toggleTitle = isHiddenByUser ? "显示挂件" : "隐藏挂件"
        let toggleItem = NSMenuItem(title: toggleTitle, action: #selector(menuToggleHidden), keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(toggleItem)

        menu.addItem(.separator())
        let configItem = NSMenuItem(title: "打开配置文件", action: #selector(menuOpenConfig), keyEquivalent: "")
        configItem.target = self
        menu.addItem(configItem)

        let quitItem = NSMenuItem(title: "退出", action: #selector(menuQuit), keyEquivalent: "")
        quitItem.target = self
        menu.addItem(quitItem)

        menu.popUp(positioning: nil, at: point, in: view)
    }

    @objc private func menuRefresh() { refresh(force: true, showPending: true) }
    @objc private func menuToggleHidden() { setHidden(!isHiddenByUser) }
    @objc private func menuOpenConfig() {
        PetConfig.writeTemplateIfMissing()
        NSWorkspace.shared.open(Paths.configFile)
    }
    @objc private func menuQuit() { NSApp.terminate(nil) }

    // MARK: 轮询

    private func startPolling() {
        pollTimer?.invalidate()
        let interval = max(POLL_MIN_SECONDS, config.pollSeconds)
        pollTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    private func observeScreens() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            let size = self.petWindow.frame.size
            self.petWindow.setFrameOrigin(PetGeometry.clamp(origin: self.petWindow.frame.origin, size: size))
            self.syncChipPosition()
        })
    }

    private func refresh(force: Bool = false, showPending: Bool = false) {
        if showPending { petView.setBubbleText("余额：……", color: NSColor(calibratedWhite: 0.36, alpha: 1)) }
        client.read(force: force) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let snapshot):
                self.lastBalanceAt = Date()
                let info = snapshot.chosen
                let text = "余额：\(symbolFor(info.currency))\(formatTotal(info.total))"
                let color = snapshot.available
                    ? NSColor(calibratedWhite: 0.10, alpha: 1)
                    : NSColor(calibratedRed: 0.69, green: 0.23, blue: 0.18, alpha: 1)
                self.petView.setBubbleText(text, color: color)
                self.petView.toolTip = "\(info.currency) 余额 \(info.total) · 赠送 \(info.granted) · 充值 \(info.toppedUp)"
                    + " · \(snapshot.available ? "账户可用" : "账户不可用")"
                    + " · 更新于 \(DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium))"
                    + "\n拖动移动 · 单击刷新 · 右键菜单"
                Log.write("balance \(info.currency) \(info.total) (available \(snapshot.available))")
            case .failure(let error):
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                self.petView.setBubbleText("余额：获取失败", color: NSColor(calibratedRed: 0.69, green: 0.23, blue: 0.18, alpha: 1))
                self.petView.toolTip = "\(message)\n单击可重试"
                Log.write("balance failed: \(message)")
            }
        }
    }
}

// MARK: - 入口

@main
struct BalancePetApp {
    static func main() {
        if CommandLine.arguments.contains("--selftest") { SelfTest.run() }
        if CommandLine.arguments.contains("--print-paths") {
            print("config:      \(Paths.configFile.path)")
            print("log:         \(Paths.logFile.path)")
            print("credentials: \(Paths.credentialsFile.path)")
            exit(0)
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)      // 无 Dock 图标、无菜单栏
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: PetController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        PetConfig.writeTemplateIfMissing()
        let controller = PetController()
        self.controller = controller
        controller.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

// MARK: - 无窗口自检

private enum SelfTest {
    static func run() -> Never {
        let config = PetConfig.load()
        print("config: poll=\(config.pollSeconds)s width=\(config.width)pt currency=\(config.currency) api=\(config.apiBase)")
        do {
            let key = try readApiKey()
            print("api key: found (\(key.count) chars, \(key.prefix(6))…)")
        } catch {
            print("api key: FAILED — \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)")
            exit(1)
        }

        let artwork = loadArtwork(shadow: config.shadow)
        print("artwork: \(artwork == nil ? "MISSING" : "ok (\(Int(artwork!.pixelWidth))x\(Int(artwork!.pixelHeight))px, pad \(Int(artwork!.pad)))")")
        if artwork == nil { exit(1) }

        let semaphore = DispatchSemaphore(value: 0)
        let client = BalanceClient(config: config)
        var code: Int32 = 1
        client.read(force: true, onMain: false) { result in
            switch result {
            case .success(let snapshot):
                let info = snapshot.chosen
                print("balance: \(info.currency) \(symbolFor(info.currency))\(info.total) (granted \(info.granted), topped up \(info.toppedUp), available \(snapshot.available))")
                print("all: \(snapshot.infos.map { "\($0.currency):\($0.total)" }.joined(separator: ", "))")
                code = 0
            case .failure(let error):
                print("balance: FAILED — \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)")
            }
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + REQUEST_TIMEOUT_SECONDS + 5)
        exit(code)
    }
}
