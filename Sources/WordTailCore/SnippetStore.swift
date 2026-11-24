import Foundation

public struct TextSnippet: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var trigger: String
    public var title: String
    public var body: String
    public var scopedBundleIDs: [String]
    public var isEnabled: Bool
    public var updatedAt: TimeInterval
    public var isDeleted: Bool

    public init(
        id: String = UUID().uuidString,
        trigger: String,
        title: String,
        body: String,
        scopedBundleIDs: [String] = [],
        isEnabled: Bool = true,
        updatedAt: TimeInterval = Date().timeIntervalSince1970,
        isDeleted: Bool = false
    ) {
        self.id = id
        self.trigger = trigger
        self.title = title
        self.body = body
        self.scopedBundleIDs = scopedBundleIDs
        self.isEnabled = isEnabled
        self.updatedAt = updatedAt
        self.isDeleted = isDeleted
    }
}

public struct SnippetMatch: Equatable, Sendable {
    public let snippet: TextSnippet
    public let trigger: String
    public let expandedText: String
    public let cursorBackSteps: Int
    public let deleteCount: Int
}

public final class SnippetStore {
    public struct SyncShard: Codable, Equatable, Sendable {
        public var records: [String: TextSnippet]

        public init(records: [String: TextSnippet] = [:]) {
            self.records = records
        }
    }

    private static let delimiters = Set(";/:!@#\\")
    private static let maximumTriggerLength = 24
    private static let macroPattern = try! NSRegularExpression(pattern: #"\{([^{}\r\n]*)\}"#)
    private static let dateFormatFields = Set("AaBbcdDeEFgGhHkKLmMOqQrsSuUvVwWxXyYzZ")

    private static let starterSnippets = [
        TextSnippet(id: ";date", trigger: ";date", title: "Date", body: "{date}", updatedAt: 0),
        TextSnippet(id: ";iso", trigger: ";iso", title: "ISO Timestamp", body: "{iso}", updatedAt: 0),
        TextSnippet(id: ";time", trigger: ";time", title: "Time", body: "{time}", updatedAt: 0),
        TextSnippet(id: ";meet", trigger: ";meet", title: "Meeting Notes",
                    body: "Meeting notes for {date}\n\nNotes\n{cursor}\n\nAction items\n", updatedAt: 0),
        TextSnippet(id: ";pr", trigger: ";pr", title: "Pull Request",
                    body: "## Summary\n{cursor}\n\n## Testing\n", updatedAt: 0),
        TextSnippet(id: ";clip", trigger: ";clip", title: "Clipboard", body: "{clipboard}", updatedAt: 0)
    ]

    private let fileURL: URL
    private let lock = NSLock()
    private var records: [String: TextSnippet]
    private var snippetsByTrigger: [String: [TextSnippet]]

    public init(directoryURL: URL? = nil) {
        let directory = directoryURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!.appendingPathComponent("WordTail", isDirectory: true)
        let fileURL = directory.appendingPathComponent("snippets.json")
        self.fileURL = fileURL

        if FileManager.default.fileExists(atPath: fileURL.path) {
            let shard = (try? Data(contentsOf: fileURL)).flatMap { try? JSONDecoder().decode(SyncShard.self, from: $0) }
            records = shard?.records.filter { Self.isValidRecord($0.value, id: $0.key) } ?? [:]
            snippetsByTrigger = Self.makeTriggerIndex(records)
        } else {
            records = Dictionary(uniqueKeysWithValues: Self.starterSnippets.map { ($0.id, $0) })
            snippetsByTrigger = Self.makeTriggerIndex(records)
            try? persist(records)
        }
    }

    public var snippets: [TextSnippet] {
        lock.withLock {
            records.values.filter { !$0.isDeleted }.sorted { $0.id < $1.id }
        }
    }

    public static func isValidTrigger(_ trigger: String) -> Bool {
        guard let first = trigger.first, delimiters.contains(first),
              (2...maximumTriggerLength).contains(trigger.count) else { return false }
        return !trigger.contains(where: \.isWhitespace)
    }

    public func match(
        textBeforeCursor: String,
        bundleID: String?,
        now: Date = Date(),
        clipboardText: String? = nil,
        clipboardTextProvider: (() -> String?)? = nil
    ) -> SnippetMatch? {
        let snippet = lock.withLock {
            matchingSnippet(textBeforeCursor: textBeforeCursor, bundleID: bundleID)
        }
        guard let snippet else { return nil }
        return Self.buildMatch(
            for: snippet,
            now: now,
            clipboardText: clipboardText,
            clipboardTextProvider: clipboardTextProvider
        )
    }

    public func expandSnippet(
        id: String,
        expectedUpdatedAt: TimeInterval?,
        bundleID: String?,
        now: Date = Date(),
        clipboardText: String? = nil,
        clipboardTextProvider: (() -> String?)? = nil
    ) -> SnippetMatch? {
        let snippet: TextSnippet? = lock.withLock {
            guard let candidate = records[id],
                  !candidate.isDeleted,
                  candidate.isEnabled,
                  Self.matchesBundle(candidate, bundleID: bundleID) else {
                return nil
            }
            if let expectedUpdatedAt, candidate.updatedAt != expectedUpdatedAt {
                return nil
            }
            return candidate
        }
        guard let snippet else { return nil }
        return Self.buildMatch(
            for: snippet,
            now: now,
            clipboardText: clipboardText,
            clipboardTextProvider: clipboardTextProvider
        )
    }

    private static func buildMatch(
        for snippet: TextSnippet,
        now: Date,
        clipboardText: String?,
        clipboardTextProvider: (() -> String?)?
    ) -> SnippetMatch {
        let resolvedClipboard = clipboardText ?? (snippet.body.contains("{clipboard}") ? clipboardTextProvider?() : nil)
        let expanded = expand(body: snippet.body, now: now, clipboardText: resolvedClipboard)
        return SnippetMatch(
            snippet: snippet,
            trigger: snippet.trigger,
            expandedText: expanded.text,
            cursorBackSteps: expanded.cursorBackSteps,
            deleteCount: snippet.trigger.count
        )
    }

    private static func matchesBundle(_ snippet: TextSnippet, bundleID: String?) -> Bool {
        snippet.scopedBundleIDs.isEmpty || bundleID.map { snippet.scopedBundleIDs.contains($0) } == true
    }

    private func matchingSnippet(textBeforeCursor: String, bundleID: String?) -> TextSnippet? {
        var start = textBeforeCursor.endIndex
        var match: TextSnippet?
        for length in 1...Self.maximumTriggerLength {
            guard start > textBeforeCursor.startIndex else { break }
            textBeforeCursor.formIndex(before: &start)
            let character = textBeforeCursor[start]
            if character.isWhitespace { break }
            guard length >= 2, Self.delimiters.contains(character) else { continue }

            if start > textBeforeCursor.startIndex {
                let boundary = textBeforeCursor[textBeforeCursor.index(before: start)]
                guard boundary.isWhitespace || Self.delimiters.contains(boundary) else { continue }
            }

            let trigger = String(textBeforeCursor[start...])
            if let candidate = snippetsByTrigger[trigger]?.first(where: { Self.matchesBundle($0, bundleID: bundleID) }) {
                match = candidate
            }
        }
        return match
    }

    public static func expand(
        body: String,
        now: Date = Date(),
        clipboardText: String? = nil
    ) -> (text: String, cursorBackSteps: Int) {
        let source = body as NSString
        var text = ""
        var textBeforeCursor: String?
        var offset = 0
        for macro in macroPattern.matches(in: body, range: NSRange(location: 0, length: source.length)) {
            text += source.substring(with: NSRange(location: offset, length: macro.range.location - offset))
            offset = NSMaxRange(macro.range)
            let name = source.substring(with: macro.range(at: 1))
            switch name {
            case "date": text += formatDate(now, format: "yyyy-MM-dd")
            case "time": text += formatDate(now, format: "HH:mm")
            case "iso": text += ISO8601DateFormatter().string(from: now)
            case "weekday": text += formatDate(now, format: "EEEE")
            case "clipboard": text += clipboardText ?? ""
            case "cursor":
                if textBeforeCursor == nil {
                    textBeforeCursor = text
                    text = ""
                }
            default:
                let format = name.dropFirst(5)
                if name.hasPrefix("date:"), isValidDateFormat(format) {
                    let formatted = formatDate(now, format: String(format))
                    text += formatted.isEmpty ? source.substring(with: macro.range) : formatted
                } else {
                    text += source.substring(with: macro.range)
                }
            }
        }
        text += source.substring(from: offset)
        guard let textBeforeCursor else { return (text, 0) }
        return (textBeforeCursor + text, text.count)
    }

    private static func formatDate(_ date: Date, format: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = format
        return formatter.string(from: date)
    }

    private static func isValidDateFormat(_ format: Substring) -> Bool {
        var insideLiteral = false
        var hasField = false
        for character in format {
            if character == "'" {
                insideLiteral.toggle()
            } else if !insideLiteral && character.isASCII && character.isLetter {
                guard dateFormatFields.contains(character) else { return false }
                hasField = true
            }
        }
        return hasField && !insideLiteral
    }

    @discardableResult
    public func addOrUpdateSnippet(_ snippet: TextSnippet) -> Bool {
        guard Self.isValidRecord(snippet, id: snippet.id) else { return false }
        return lock.withLock { saveLocalEdit(snippet) }
    }

    @discardableResult
    public func toggleSnippet(id: String, isEnabled: Bool) -> Bool {
        lock.withLock {
            guard var snippet = records[id], !snippet.isDeleted else { return false }
            guard snippet.isEnabled != isEnabled else { return true }
            snippet.isEnabled = isEnabled
            return saveLocalEdit(snippet)
        }
    }

    @discardableResult
    public func deleteSnippet(id: String) -> Bool {
        lock.withLock {
            guard var snippet = records[id] else { return false }
            guard !snippet.isDeleted || !snippet.body.isEmpty || !snippet.title.isEmpty || !snippet.trigger.isEmpty else {
                return true
            }
            snippet.isDeleted = true
            snippet.isEnabled = false
            snippet.trigger = ""
            snippet.title = ""
            snippet.body = ""
            snippet.scopedBundleIDs = []
            return saveLocalEdit(snippet)
        }
    }

    public func exportJSON() throws -> Data {
        try Self.encode(exportLocalShard())
    }

    /// Returns the number of records inserted or updated by the import.
    @discardableResult
    public func importJSON(_ data: Data) throws -> Int {
        let shard = try JSONDecoder().decode(SyncShard.self, from: data)
        for (id, snippet) in shard.records where !Self.isValidRecord(snippet, id: id) {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Invalid snippet record: \(id)"))
        }
        return try lock.withLock { try merge([shard]) }
    }

    public func exportLocalShard() -> SyncShard {
        lock.withLock { SyncShard(records: records) }
    }

    @discardableResult
    public func applyRemoteShards(_ shards: [String: SyncShard]) -> Bool {
        lock.withLock {
            do {
                _ = try merge(shards.sorted { $0.key < $1.key }.map(\.value))
                return true
            } catch {
                return false
            }
        }
    }

    private static func isValidRecord(_ snippet: TextSnippet, id: String) -> Bool {
        !id.isEmpty && snippet.id == id && snippet.updatedAt.isFinite
            && (snippet.isDeleted || isValidTrigger(snippet.trigger))
    }

    private func saveLocalEdit(_ snippet: TextSnippet) -> Bool {
        var updated = snippet
        let now = Date().timeIntervalSince1970
        updated.updatedAt = max(now, records[snippet.id]?.updatedAt.nextUp ?? now)
        var snapshot = records
        snapshot[updated.id] = updated
        do {
            try commit(snapshot)
            return true
        } catch {
            return false
        }
    }

    private func merge(_ shards: [SyncShard]) throws -> Int {
        var snapshot = records
        var changedIDs = Set<String>()
        for shard in shards {
            for (id, incoming) in shard.records where Self.isValidRecord(incoming, id: id) {
                if let current = snapshot[id], !Self.shouldIncomingWin(incoming, over: current) {
                    continue
                }
                snapshot[id] = incoming
                changedIDs.insert(id)
            }
        }
        if !changedIDs.isEmpty { try commit(snapshot) }
        return changedIDs.count
    }

    private static func shouldIncomingWin(_ incoming: TextSnippet, over current: TextSnippet) -> Bool {
        if incoming.updatedAt != current.updatedAt {
            return incoming.updatedAt > current.updatedAt
        }
        if incoming.isDeleted != current.isDeleted {
            return incoming.isDeleted
        }
        if incoming.body != current.body { return incoming.body > current.body }
        if incoming.title != current.title { return incoming.title > current.title }
        if incoming.trigger != current.trigger { return incoming.trigger > current.trigger }
        if incoming.isEnabled != current.isEnabled { return incoming.isEnabled && !current.isEnabled }
        return current.scopedBundleIDs.lexicographicallyPrecedes(incoming.scopedBundleIDs)
    }

    private func commit(_ snapshot: [String: TextSnippet]) throws {
        try persist(snapshot)
        records = snapshot
        snippetsByTrigger = Self.makeTriggerIndex(snapshot)
    }

    private func persist(_ snapshot: [String: TextSnippet]) throws {
        let data = try Self.encode(SyncShard(records: snapshot))
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }

    private static func encode(_ shard: SyncShard) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(shard)
    }

    private static func makeTriggerIndex(_ records: [String: TextSnippet]) -> [String: [TextSnippet]] {
        let enabled = records.values.filter { $0.isEnabled && !$0.isDeleted }.sorted {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.id < $1.id
        }
        return Dictionary(grouping: enabled, by: \.trigger)
    }
}
