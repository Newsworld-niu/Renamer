import Foundation

struct Desktop: Equatable {
    let sessionID: UInt64
    let persistentID: String?
    let displayID: String
    let screenID: UInt32
    let screenName: String
    let position: Int
    let isCurrent: Bool
    let isOrdinary: Bool

    func identity(bootID: String) -> String {
        if let id = persistentID?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty {
            return "uuid:" + id.uppercased()
        }
        return "session:\(bootID):\(sessionID)"
    }
}

struct NameRecord: Codable, Equatable {
    var name: String
    var lastDisplay: String
    var neighbors: NeighborAnchors? = nil
}

struct NeighborAnchors: Codable, Equatable {
    let before: String
    let after: String
}

struct SavedNames: Codable {
    var version = 1
    var records: [String: NameRecord] = [:]
}

enum RenamerError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let message): return message }
    }
}

final class NameStore {
    let url: URL
    let bootID: String
    private(set) var data = SavedNames()
    private(set) var loadError: String?

    init(url: URL, bootID: String) {
        self.url = url
        self.bootID = bootID
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                data = try JSONDecoder().decode(SavedNames.self, from: Data(contentsOf: url))
                guard data.version == 1 else { throw RenamerError.message(L("名称文件版本不受支持，已停止写入。")) }
            } catch { loadError = L("名称文件无法读取，原文件已保留：%@", error.localizedDescription) }
        }
    }

    func customName(_ space: Desktop) -> String? {
        data.records[space.identity(bootID: bootID)]?.name
    }

    private func anchors(for space: Desktop, among spaces: [Desktop]) -> NeighborAnchors? {
        guard space.persistentID == nil else { return nil }
        let ordered = spaces.filter { $0.displayID == space.displayID && $0.isOrdinary }
            .sorted { $0.position < $1.position }
        guard let index = ordered.firstIndex(where: { $0.sessionID == space.sessionID }),
              index > 0, index + 1 < ordered.count,
              let before = ordered[index - 1].persistentID?.uppercased(), !before.isEmpty,
              let after = ordered[index + 1].persistentID?.uppercased(), !after.isEmpty else { return nil }
        return NeighborAnchors(before: before, after: after)
    }

    // Only restore a UUID-less name when both adjacent UUIDs identify exactly
    // one live desktop. Never use its position or recycled numeric ID alone.
    func reconcile(_ spaces: [Desktop]) throws {
        if let error = loadError { throw RenamerError.message(error) }
        var next = data
        let missing = spaces.filter { $0.persistentID == nil && $0.isOrdinary }
        for space in missing {
            let key = space.identity(bootID: bootID)
            guard let neighborPair = anchors(for: space, among: spaces) else { continue }
            if var record = next.records[key] {
                if record.neighbors != neighborPair {
                    record.neighbors = neighborPair
                    next.records[key] = record
                }
                continue
            }
            guard missing.filter({ anchors(for: $0, among: spaces) == neighborPair }).count == 1 else { continue }
            let candidates = next.records.filter { entry in
                entry.key.hasPrefix("session:") && entry.value.neighbors == neighborPair
            }
            guard candidates.count == 1, let source = candidates.first else { continue }
            var record = source.value
            record.lastDisplay = space.screenName
            next.records[key] = record
            next.records.removeValue(forKey: source.key)
        }
        guard next.records != data.records else { return }
        try save(next)
    }

    func name(_ space: Desktop) -> String {
        customName(space) ?? (space.isOrdinary ? L("桌面 %d", space.position) : L("全屏空间 %d", space.position))
    }

    func rename(_ space: Desktop, to name: String, among spaces: [Desktop] = []) throws {
        if let error = loadError { throw RenamerError.message(error) }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= 80 else { throw RenamerError.message(L("名称最多 80 个字符。")) }
        var next = data
        let key = space.identity(bootID: bootID)
        if trimmed.isEmpty { next.records.removeValue(forKey: key) }
        else { next.records[key] = NameRecord(name: trimmed, lastDisplay: space.screenName,
                                              neighbors: anchors(for: space, among: spaces)) }
        try save(next)
    }

    private func save(_ next: SavedNames) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(next).write(to: url, options: .atomic)
        data = next
    }

    func filtered(_ spaces: [Desktop], query: String) -> [Desktop] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let ordinary = spaces.filter(\.isOrdinary)
        guard !query.isEmpty else { return ordinary }
        return ordinary.filter { name($0).localizedStandardContains(query) }.sorted {
            let a = name($0).compare(query, options: .caseInsensitive) == .orderedSame
            let b = name($1).compare(query, options: .caseInsensitive) == .orderedSame
            if a != b { return a }
            if $0.displayID != $1.displayID { return $0.displayID < $1.displayID }
            return $0.position < $1.position
        }
    }

    func unmatchedCount(_ spaces: [Desktop]) -> Int {
        let live = Set(spaces.map { $0.identity(bootID: bootID) })
        return data.records.keys.filter { !live.contains($0) }.count
    }
}
