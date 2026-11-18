import AppKit
import BlazebunnyCore

extension Notification.Name {
    /// Posted by the bench to open or close the inspector the way the toolbar button does.
    static let benchToggleInspector = Notification.Name("bbBenchToggleInspector")
}

/// Counters the grid keeps for the bench (plain integers; nothing is measured unless logging is on).
@MainActor
enum GridStats {
    static var layoutPasses = 0
    static var layoutMs = 0.0
    static var reloads = 0
    static var applyMs = 0.0
    /// Time from a cell asking for its thumbnail to showing it, in ms.
    static var thumbnailWaits: [Double] = []
    static var cellsShownFromCache = 0
    static weak var collectionView: NSCollectionView?

    static func reset() {
        layoutPasses = 0; layoutMs = 0; reloads = 0; applyMs = 0
        thumbnailWaits = []; cellsShownFromCache = 0
    }

    static var text: String {
        let w = thumbnailWaits.sorted()
        func q(_ p: Double) -> Double { w.isEmpty ? 0 : w[min(w.count - 1, Int(Double(w.count) * p))] }
        return String(format: "layout passes %d (%.1f ms), reloads %d, apply %.1f ms, thumbs cached %d, loaded %d (p50 %.1f p95 %.1f max %.1f ms)",
                      layoutPasses, layoutMs, reloads, applyMs, cellsShownFromCache, w.count, q(0.5), q(0.95), w.last ?? 0)
    }
}

/// `--bench`: drives the app through the things people do (open and close the side panels, resize
/// thumbnails, change folder, filter, search, scroll, arrow through images) and logs how long the
/// main thread was busy during each. Needs `BB_PERF_LOG`. Development only, like `--open`.
@MainActor
final class PerfBench {
    private static var shared: PerfBench?
    private let model: LibraryModel
    private let watch = MainThreadWatch()

    static func startIfRequested(model: LibraryModel) {
        guard shared == nil, Perf.isLogging, CommandLine.arguments.contains("--bench") else { return }
        let bench = PerfBench(model: model)
        shared = bench
        Task { await bench.run() }
    }

    private init(model: LibraryModel) { self.model = model }

    private func pause(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }

    /// `BB_BENCH_ONLY=a,b` runs only the phases whose name starts with one of the prefixes. (An
    /// environment variable, because AppKit takes a bare extra argument for a file to open and
    /// then does not open the main window.)
    private let only = (ProcessInfo.processInfo.environment["BB_BENCH_ONLY"] ?? "").split(separator: ",").map(String.init)

    private func phase(_ name: String, settle: Double = 0.6, _ body: () async -> Void) async {
        guard only.isEmpty || only.contains(where: { name.hasPrefix($0) }) else { return }
        GridStats.reset()
        Perf.log("phase \(name)")
        let cpu = Perf.threadCPUms()
        watch.start()
        await body()
        await pause(settle)
        let r = watch.stop()
        // CPU time of the main thread is what the app itself spent; the stalls also count time it
        // waited for the window server, which is longer when nobody can see the window.
        Perf.log(String(format: "result %@: main cpu %.1f ms; %@; %@", name, Perf.threadCPUms() - cpu, r.text, GridStats.text))
    }

    private func run() async {
        // A window nobody is looking at is put to sleep by App Nap, which shows up as stalls of
        // hundreds of milliseconds that no user would ever see. Not while measuring.
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "Blazebunny bench")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        // Wait for a loaded library with no scan running.
        for tick in 0..<6000 {
            let scanning = model.progress.map { $0.phase != .done } ?? false
            if model.library != nil, !model.items.isEmpty, !scanning, !model.isPartialPage, model.scanFinished || !model.isOnline { break }
            await pause(0.1)
            // A first scan: thumbnails must appear while it runs.
            if [15, 40, 80].contains(tick) { Perf.snapshot("00-scanning-\(tick)") }
        }
        await pause(2)
        Perf.log("bench.items \(model.items.count)")
        Perf.snapshot("01-loaded")
        Perf.log("bench.screens \(NSScreen.screens.count) windows \(NSApp.windows.map { "\($0.isVisible ? "visible" : "hidden"):\(Int($0.frame.width))x\(Int($0.frame.height))" })")
        if let w = NSApp.windows.first(where: { $0.contentView != nil && $0.isVisible }) {
            // A window nobody can see is not drawn, so its numbers would mean nothing.
            Perf.log("bench.window visible=\(w.occlusionState.contains(.visible)) active=\(NSApp.isActive) key=\(w.isKeyWindow) size=\(Int(w.frame.width))x\(Int(w.frame.height)) scale=\(w.backingScaleFactor) hz=\(w.screen?.maximumFramesPerSecond ?? 0)")
        }

        for i in 0..<6 {
            await phase("inspector.toggle.\(i)", settle: 0.9) {
                NotificationCenter.default.post(name: .benchToggleInspector, object: nil)
                if i < 2 {
                    // Mid-slide (the rows must not have moved), mid-glide and at rest.
                    for (k, wait) in [0.15, 0.2, 0.08, 0.08, 0.3].enumerated() { await pause(wait); Perf.snapshot("02-inspector-\(i)-\(k)") }
                }
            }
        }
        for i in 0..<6 {
            await phase("sidebar.toggle.\(i)", settle: 0.9) {
                Self.splitViewController()?.toggleSidebar(nil)
            }
        }
        await phase("slider.drag") {
            for step in 1...40 { model.cellSize = 160 + Double(step) * 3; await pause(0.016); if step == 20 { Perf.snapshot("03-slider-mid") } }
            await pause(0.4)
            Perf.snapshot("03-slider-big")
            for step in 1...40 { model.cellSize = 280 - Double(step) * 3; await pause(0.016) }
        }
        for i in 0..<4 { await phase("fillfit.\(i)", settle: 0.5) { model.fillCells.toggle(); if i == 0 { await pause(0.4); Perf.snapshot("04-fit") } } }

        let folder = model.folderRows.first?.id
        if let folder {
            await phase("scope.folder") { model.selectSidebar(.folder(folder)) }
            if let path = model.currentPath { await phase("scope.library") { model.selectSidebar(.library(path)) } }
        }
        await phase("filter.source.on") { model.toggle(.source, ItemSource.midjourney.rawValue) }
        await phase("filter.source.off") { model.clearAll() }
        await phase("search.common", settle: 0.9) { model.query.text = "lantern" }
        await phase("search.clear", settle: 0.9) { model.query.text = "" }

        await scroll(name: "scroll.slow", pointsPerSecond: 3000, seconds: 3)
        Perf.snapshot("05-scrolled")
        // Deep in the list, a side panel must leave the same pictures on screen.
        await phase("inspector.deep.close", settle: 1.0) { NotificationCenter.default.post(name: .benchToggleInspector, object: nil) }
        Perf.snapshot("05-scrolled-inspector-closed")
        await phase("inspector.deep.open", settle: 1.0) { NotificationCenter.default.post(name: .benchToggleInspector, object: nil) }
        Perf.snapshot("05-scrolled-inspector-open")
        await scroll(name: "scroll.fast", pointsPerSecond: 30000, seconds: 3)
        await scroll(name: "scroll.back", pointsPerSecond: -60000, seconds: 2)

        await phase("select.keyrepeat") { await select(count: 60, every: 0.033) }
        await phase("select.slow", settle: 1.0) { await select(count: 12, every: 0.45, from: 60, snapshot: "06-selected") }
        if let big = model.folderRows.first(where: { $0.node.name == "Big" })?.id {
            await phase("scope.big") { model.selectSidebar(.folder(big)) }
            await phase("preview.big", settle: 1.5) { await select(count: 10, every: 0.6) }
            if let path = model.currentPath { await phase("scope.library.2") { model.selectSidebar(.library(path)) } }
        }
        Perf.log("bench.rss.mb", Perf.residentMB())
        Perf.log("bench.done")
        await pause(0.3)
        NSApp.terminate(nil)
    }

    /// The split view behind `NavigationSplitView`, to open and close the sidebar like its toolbar button.
    private static func splitViewController() -> NSSplitViewController? {
        func find(_ view: NSView) -> NSSplitViewController? {
            if let split = view as? NSSplitView, let c = split.delegate as? NSSplitViewController, c.splitViewItems.count >= 2,
               c.splitViewItems.contains(where: { $0.behavior == .sidebar }) { return c }
            for sub in view.subviews { if let c = find(sub) { return c } }
            return nil
        }
        for window in NSApp.windows { if let content = window.contentView, let c = find(content) { return c } }
        return nil
    }

    private func scroll(name: String, pointsPerSecond: Double, seconds: Double) async {
        guard let cv = GridStats.collectionView, let scrollView = cv.enclosingScrollView else { return }
        await phase(name, settle: 1.0) {
            let clip = scrollView.contentView
            let start = Perf.now()
            var last = start
            while Perf.ms(since: start) < seconds * 1000 {
                let dt = Perf.ms(since: last) / 1000
                last = Perf.now()
                let maxY = max(0, cv.frame.height - clip.bounds.height)
                let y = min(maxY, max(0, clip.bounds.origin.y + pointsPerSecond * dt))
                clip.setBoundsOrigin(NSPoint(x: 0, y: y))
                scrollView.reflectScrolledClipView(clip)
                await pause(0.004)
            }
        }
    }

    /// Selects successive items the way holding an arrow key does.
    private func select(count: Int, every: Double, from: Int = 0, snapshot: String? = nil) async {
        guard let cv = GridStats.collectionView else { return }
        var flat = 0
        var paths: [IndexPath] = []
        for s in 0..<cv.numberOfSections {
            for i in 0..<cv.numberOfItems(inSection: s) {
                if flat >= from { paths.append(IndexPath(item: i, section: s)) }
                flat += 1
                if paths.count == count { break }
            }
            if paths.count == count { break }
        }
        for (n, p) in paths.enumerated() {
            cv.selectionIndexPaths = [p]
            cv.delegate?.collectionView?(cv, didSelectItemsAt: [p])
            await pause(every)
            if n == 2, let snapshot { Perf.snapshot(snapshot) }
        }
        cv.selectionIndexPaths = []
        model.selection = []
    }
}
