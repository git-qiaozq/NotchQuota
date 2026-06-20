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
        DispatchQueue.global(qos: .userInitiated).async {
            let result = runProbe()
            DispatchQueue.main.async { completion(result) }
        }
    }

    private static func runProbe() -> [QuotaService] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["python3", probePath]
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
}
