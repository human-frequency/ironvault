import Darwin
import Foundation

/// Notices when a sealed file is read outside IronVault.
///
/// macOS doesn't tell ordinary apps who reads a file. What it does keep is each file's
/// "last accessed" time. The watchdog sets that time just before the file's "last modified"
/// time; macOS moves it forward on the next read, and the watchdog notices on its next pass.
/// It then asks `lsof` which program has the file open, which only works if the reader is
/// still holding it. Readers that finish within a moment show as "unknown".
public enum AccessMonitor {
    struct Entry: Codable { var mtime: Double; var armed: Double }

    static func stateURL(_ config: VaultConfig) -> URL {
        config.home.appendingPathComponent("Library/Application Support/IronVault/watch-state.json")
    }

    static func times(_ path: String) -> (atime: Double, mtime: Double)? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        let a = Double(info.st_atimespec.tv_sec) + Double(info.st_atimespec.tv_nsec) / 1e9
        let m = Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9
        return (a, m)
    }

    /// Sets "last accessed" one second before "last modified", so the next read is visible.
    @discardableResult
    static func arm(_ path: String, mtime: Double) -> Double? {
        let armed = Int(mtime) - 1
        var stamps = [timespec(tv_sec: armed, tv_nsec: 0), timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT))]
        guard utimensat(AT_FDCWD, path, &stamps, 0) == 0 else { return nil }
        return Double(armed)
    }

    /// One pass over the vault. `ownOpens` are IronVault's own approved opens (file → time),
    /// which are not reported. Returns the reads it found.
    public static func scan(_ config: VaultConfig, ownOpens: [String: Date]) -> [ActivityEvent] {
        let decoder = JSONDecoder()
        var state = (try? Data(contentsOf: stateURL(config))).flatMap { try? decoder.decode([String: Entry].self, from: $0) } ?? [:]
        var events: [ActivityEvent] = []
        var seen = Set<String>()

        for url in VaultFiles.listSealed(config) {
            let path = url.path
            seen.insert(path)
            guard let t = times(path) else { continue }
            if let entry = state[path], entry.mtime == t.mtime {
                guard t.atime > entry.armed + 0.5 else { continue }   // not read since last pass
                let relative = ActivityLog.relativePath(url, in: config)
                let readAt = Date(timeIntervalSince1970: t.atime)
                let own = ownOpens[relative].map { abs($0.timeIntervalSince(readAt)) < 90 } ?? false
                if !own && !backupRunning() {
                    let who = readers(of: path)
                    events.append(ActivityEvent(time: readAt, kind: .read, files: [relative],
                                                by: who, unusual: who.map(isUnusual) ?? false))
                }
            }
            // New, changed or just read: arm it again.
            if let armed = arm(path, mtime: t.mtime) {
                state[path] = Entry(mtime: t.mtime, armed: armed)
            }
        }
        state = state.filter { seen.contains($0.key) }
        if let data = try? JSONEncoder().encode(state) {
            try? FileManager.default.createDirectory(at: stateURL(config).deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try? data.write(to: stateURL(config), options: .atomic)
        }
        return events
    }

    /// Time Machine reads changed files during a backup. Those reads are expected, so they
    /// aren't reported. (Re-arming a file counts as a change, so backups do read vault files.)
    static var backupCheck: (at: Date, running: Bool)?
    static func backupRunning() -> Bool {
        if let c = backupCheck, Date().timeIntervalSince(c.at) < 10 { return c.running }
        let running = VaultFiles.capture("/usr/bin/tmutil", ["status"]).contains("Running = 1")
        backupCheck = (Date(), running)
        return running
    }

    /// Checks once whether this Mac records reads at all (it doesn't if the disk is mounted "noatime").
    public static func readsAreRecorded(at path: String) -> Bool {
        guard let t = times(path), let armed = arm(path, mtime: t.mtime),
              let handle = FileHandle(forReadingAtPath: path) else { return false }
        _ = handle.readData(ofLength: 16)
        try? handle.close()
        let after = times(path)?.atime ?? armed
        arm(path, mtime: t.mtime)
        return after > armed + 0.5
    }

    // MARK: Who is reading

    /// Names of programs that have `path` open right now (or anything inside it, for a folder).
    public static func readers(of path: String, excluding pid: Int32? = nil) -> String? {
        let list = openers(of: path, excluding: pid)
        return list.isEmpty ? nil : Array(Set(list.map { $0.name })).sorted().joined(separator: ", ")
    }

    public static func openers(of path: String, excluding pid: Int32? = nil) -> [(pid: Int32, name: String)] {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        let args = ["+c", "0", "-Fpc"] + (isDir.boolValue ? ["+D", path] : ["--", path])
        var result: [(pid: Int32, name: String)] = []
        var current: Int32?
        for line in VaultFiles.capture("/usr/sbin/lsof", args).split(separator: "\n") {
            if line.hasPrefix("p") { current = Int32(line.dropFirst()) }
            else if line.hasPrefix("c"), let p = current, p != pid, p != getpid() {
                result.append((pid: p, name: String(line.dropFirst())))
            }
        }
        return result
    }

    static let unusualNames: Set<String> = [
        "node", "python", "python3", "ruby", "perl", "php", "java", "deno", "bun",
        "bash", "zsh", "sh", "fish", "dash", "cat", "less", "more", "head", "tail", "grep", "rg",
        "cp", "rsync", "scp", "curl", "wget", "nc", "osascript", "strings", "xxd", "base64",
        "claude", "codex", "cursor", "ollama", "chatgpt", "copilot", "gemini", "aider", "goose",
    ]

    /// Command-line tools and AI apps. Normal document apps (Preview, Word, Pages…) are not.
    public static func isUnusual(_ name: String) -> Bool {
        name.lowercased().components(separatedBy: CharacterSet(charactersIn: ",←")).contains { part in
            let n = part.trimmingCharacters(in: .whitespaces).lowercased()
            return unusualNames.contains(n) || n.contains("cursor") || n.contains("claude")
                || n.contains("chatgpt") || n.contains("copilot") || n.hasPrefix("python")
        }
    }

    /// "open ← zsh ← node ← Terminal": the program and the ones that started it.
    public static func processChain(_ pid: Int32) -> String? {
        var names: [String] = []
        var current = pid
        for _ in 0..<6 where current > 1 {
            let out = VaultFiles.capture("/bin/ps", ["-o", "ppid=", "-o", "comm=", "-p", String(current)])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = out.split(separator: " ", maxSplits: 1)
            guard parts.count == 2, let parent = Int32(parts[0]) else { break }
            names.append((String(parts[1]).trimmingCharacters(in: .whitespaces) as NSString).lastPathComponent)
            current = parent
        }
        return names.isEmpty ? nil : names.joined(separator: " ← ")
    }
}
