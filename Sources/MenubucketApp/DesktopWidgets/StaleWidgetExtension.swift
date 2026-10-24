import Darwin
import Foundation
import WidgetKit

/// The desktop widget extension left running from before an update.
///
/// macOS keeps a widget extension's process alive across app updates: a
/// Homebrew upgrade or the in-app updater replaces the bundle, and the old
/// extension binary keeps drawing every desktop widget until the Mac
/// restarts. Seen on june-mba: an extension started at boot on 10-11 was
/// still the one running under 0.7.5 on 10-25, showing readings frozen two
/// weeks back while BarShelf published fresh ones. Ending it lets macOS start
/// the installed one the next time a widget is drawn.
enum StaleWidgetExtension {
    struct Process: Equatable {
        let pid: pid_t
        let executable: String
        let startedAt: Date
    }

    /// The extension processes running this bundle's extension path but
    /// started before that binary was written — an older copy.
    static func stale(_ processes: [Process], executable: String, builtAt: Date) -> [pid_t] {
        processes
            .filter { $0.executable == executable && $0.startedAt < builtAt.addingTimeInterval(-1) }
            .map(\.pid)
    }

    /// Ends stale extension processes and asks for fresh timelines. Returns
    /// how many were ended.
    @discardableResult
    static func restartIfStale(bundle: Bundle = .main) -> Int {
        let executable = bundle.bundleURL
            .appendingPathComponent("Contents/PlugIns/BarShelfWidgets.appex/Contents/MacOS/BarShelfWidgets")
        guard let builtAt = (try? executable.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate else { return 0 }
        let pids = stale(runningProcesses(), executable: executable.path, builtAt: builtAt)
        for pid in pids { kill(pid, SIGTERM) }
        if !pids.isEmpty {
            NSLog("barshelf: ended \(pids.count) widget extension process(es) left from before an update")
            WidgetCenter.shared.reloadAllTimelines()
        }
        return pids.count
    }

    private static func runningProcesses() -> [Process] {
        let capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(capacity) + 32)
        let count = pids.withUnsafeMutableBytes { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count))
        }
        guard count > 0 else { return [] }
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        return pids.prefix(Int(count)).compactMap { pid in
            guard pid > 0, proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
            let executable = String(cString: path)
            guard executable.hasSuffix("/BarShelfWidgets"), let started = startTime(of: pid) else { return nil }
            return Process(pid: pid, executable: executable, startedAt: started)
        }
    }

    private static func startTime(of pid: pid_t) -> Date? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec)
            + TimeInterval(info.pbi_start_tvusec) / 1_000_000)
    }
}
