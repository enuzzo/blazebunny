import AppKit
import ImageIO
import UniformTypeIdentifiers
import os

/// Timing points. Always: signpost intervals for Instruments (free when nothing records them).
/// With `BB_PERF_LOG=<file>` in the environment: a plain log of timings, used by `--bench` and when
/// measuring by hand. The log holds numbers and fixed labels only, never names, paths or prompts.
enum Perf {
    static let signposter = OSSignposter(subsystem: "io.github.enuzzo.blazebunny", category: .pointsOfInterest)
    private static let logPath = ProcessInfo.processInfo.environment["BB_PERF_LOG"].flatMap { $0.isEmpty ? nil : $0 }
    static let isLogging = logPath != nil
    private static let sink = LogSink(path: logPath)

    /// Milliseconds since the process was started (the kernel's start time, so it includes dyld and
    /// everything before `main`).
    static func sinceLaunch() -> Double {
        (Date().timeIntervalSince1970 - processStart) * 1000
    }

    static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
    static func ms(since t: UInt64) -> Double { Double(now() - t) / 1e6 }

    /// One line in the log: `label value` (value in ms unless the label says otherwise).
    static func log(_ label: String, _ value: Double? = nil) {
        guard isLogging else { return }
        sink.write(value.map { String(format: "%@ %.2f", label, $0) } ?? label)
    }

    /// Logs a launch milestone once, as ms since process start.
    @MainActor static func launchMark(_ label: String) {
        guard isLogging, !launchMarks.contains(label) else { return }
        launchMarks.insert(label)
        log("launch." + label, sinceLaunch())
    }

    @MainActor private static var launchMarks = Set<String>()

    /// A stretch of work: a signpost interval in Instruments and, when logging, a line in the log.
    struct Interval {
        fileprivate let name: StaticString
        fileprivate let state: OSSignpostIntervalState
        fileprivate let started = Perf.now()

        /// Ends the interval and returns how long it took, in ms.
        @discardableResult
        func end() -> Double {
            Perf.signposter.endInterval(name, state)
            let ms = Perf.ms(since: started)
            if Perf.isLogging { Perf.log("\(name)", ms) }
            return ms
        }
    }

    static func begin(_ name: StaticString) -> Interval {
        Interval(name: name, state: signposter.beginInterval(name))
    }

    /// With `BB_SNAPSHOT_DIR=<folder>`: draws the main window's layers, as they are at this instant
    /// (animations included), into `<folder>/<name>.png`. For checking layout and motion when nobody
    /// can look at the screen. Only ever used with generated demo folders: a picture of a real
    /// library must never be written anywhere.
    @MainActor static func snapshot(_ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["BB_SNAPSHOT_DIR"], !dir.isEmpty,
              let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
              let root = window.contentView?.superview ?? window.contentView, let layer = root.layer else { return }
        let size = root.bounds.size
        guard size.width > 0, size.height > 0,
              let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        context.setFillColor(CGColor(gray: 0.05, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        (layer.presentation() ?? layer).render(in: context)
        let url = URL(fileURLWithPath: dir).appendingPathComponent(name + ".png")
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }

    /// CPU time the calling thread has used so far, in ms.
    static func threadCPUms() -> Double {
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<natural_t>.size)
        let thread = mach_thread_self()
        defer { mach_port_deallocate(mach_task_self_, thread) }
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { thread_info(thread, thread_flavor_t(THREAD_BASIC_INFO), $0, &count) }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.user_time.seconds + info.system_time.seconds) * 1000
            + Double(info.user_time.microseconds + info.system_time.microseconds) / 1000
    }

    /// Resident memory of the app, in MB.
    static func residentMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : 0
    }

    private static let processStart: Double = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return Date().timeIntervalSince1970 }
        let tv = info.kp_proc.p_starttime
        return Double(tv.tv_sec) + Double(tv.tv_usec) / 1e6
    }()

    private final class LogSink: @unchecked Sendable {
        private let handle: FileHandle?
        private let lock = NSLock()
        init(path: String?) {
            guard let path else { handle = nil; return }
            FileManager.default.createFile(atPath: path, contents: nil)
            handle = FileHandle(forWritingAtPath: path)
        }
        func write(_ line: String) {
            lock.withLock { try? handle?.write(contentsOf: Data((line + "\n").utf8)) }
        }
    }
}

/// Measures how long the main thread fails to answer: a background thread asks it for a turn, waits,
/// and records the delay. One long stall is one sample, so the samples add up to the time the UI
/// could not draw. Used by `--bench`; nothing runs unless `start()` is called.
final class MainThreadWatch: @unchecked Sendable {
    struct Report {
        var samples = 0
        var worst = 0.0
        /// Stalls longer than one 120 Hz frame, and longer than one 60 Hz frame.
        var over8 = 0, over16 = 0
        /// Frames a 120 Hz display would have missed, summed over the stalls.
        var missedFrames = 0
        var text: String {
            String(format: "worst %.1f ms, stalls >8.3ms %d, >16.7ms %d, missed 120Hz frames %d", worst, over8, over16, missedFrames)
        }
    }

    private let lock = NSLock()
    private var report = Report()
    /// Each `start()` gets its own number, so a thread from an earlier run stops even when the next
    /// run starts before it has noticed.
    private var generation = 0

    func start() {
        let mine = lock.withLock { () -> Int in
            report = Report()
            generation += 1
            return generation
        }
        let thread = Thread { [self] in
            let done = DispatchSemaphore(value: 0)
            while lock.withLock({ generation == mine }) {
                let sent = Perf.now()
                DispatchQueue.main.async { done.signal() }
                done.wait()
                let delay = Perf.ms(since: sent)
                lock.withLock {
                    guard generation == mine else { return }
                    report.samples += 1
                    report.worst = max(report.worst, delay)
                    if delay > 8.34 { report.over8 += 1; report.missedFrames += Int(delay / 8.34) }
                    if delay > 16.7 { report.over16 += 1 }
                }
                usleep(1000)
            }
        }
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// Stops and returns what was seen since `start()`.
    func stop() -> Report {
        lock.withLock { generation += 1; return report }
    }
}
