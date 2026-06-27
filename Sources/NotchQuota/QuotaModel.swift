import Foundation

// 单条指标：要么是百分比型(used_pct)，要么是文本型(text)
struct QuotaMetric: Decodable {
    let label: String
    let usedPct: Double?
    let reset: String?
    let text: String?

    enum CodingKeys: String, CodingKey {
        case label
        case usedPct = "used_pct"
        case reset
        case text
    }
}

struct QuotaService: Decodable, Identifiable {
    let id: String
    let name: String
    let plan: String
    let status: String      // "ok" | "error"
    let detail: String
    let metrics: [QuotaMetric]
    let url: String

    var isOK: Bool { status == "ok" }
}

// 调 Python probe 脚本，拿统一 JSON
enum QuotaFetcher {
    static var probePath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/NotchQuota/probe/quota_probe.py"
    }

    static func fetch(completion: @escaping ([QuotaService]) -> Void) {
        fetch(force: false, completion: completion)
    }

    /// force=true 时(如展开面板),让 probe 跳过 Claude 的缓存,取实时数据
    static func fetch(force: Bool, completion: @escaping ([QuotaService]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = runProbe(force: force)
            DispatchQueue.main.async { completion(result) }
        }
    }

    private static func runProbe(force: Bool) -> [QuotaService] {
        let proc = makeProcess(args: [probePath])
        // force 刷新时注入环境变量,probe 据此跳过 Claude 缓存(层1降频的"按需"部分)
        if force {
            var env = proc.environment ?? [:]
            env["NOTCHQUOTA_FORCE"] = "1"
            proc.environment = env
        }
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            let decoded = try JSONDecoder().decode([QuotaService].self, from: data)
            return decoded
        } catch {
            return []
        }
    }

    /// app 退出时调用:让 agy daemon 优雅关闭,避免遗留孤儿进程
    static func shutdownDaemon() {
        let script = """
        import sys
        sys.path.insert(0, \(probeDirQuoted))
        try:
            import agy_usage
            agy_usage._daemon_request('shutdown', 3)
        except Exception:
            pass
        """
        let proc = makeProcess(args: ["-c", script])
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        do { try proc.run(); proc.waitUntilExit() } catch {}
    }
    private static var probeDirQuoted: String {
        "\"" + probeDir.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    // 复用:带补全 PATH 的 Python 进程
    private static func makeProcess(args: [String]) -> Process {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["python3"] + args
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var env = ProcessInfo.processInfo.environment
        let extraPaths = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
        let existing = env["PATH"] ?? "/usr/bin:/bin"
        env["PATH"] = (extraPaths.joined(separator: ":") + ":" + existing)
        proc.environment = env
        return proc
    }
    private static var probeDir: String {
        (probePath as NSString).deletingLastPathComponent
    }
}
