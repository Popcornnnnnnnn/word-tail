import Foundation

/// Identifies a physical or logical display for optional display-scoped baseline calibration.
public struct DisplayDescriptor: Equatable, Hashable, Codable, Sendable {
    public let key: String
    public let name: String

    public init(key: String, name: String) {
        self.key = key
        self.name = name
    }
}

/// Identifies the active target application (and optional display) for baseline calibration controls.
public struct CalibrationAppInfo: Equatable, Sendable {
    public let name: String
    public let bundleID: String
    public let displayKey: String?
    public let displayName: String?

    public init(
        name: String,
        bundleID: String,
        displayKey: String? = nil,
        displayName: String? = nil
    ) {
        self.name = name
        self.bundleID = bundleID
        self.displayKey = displayKey
        self.displayName = displayName
    }
}

/// Single source of truth for WordTail's vertical ghost-text baseline calibration offsets.
///
/// Persists calibration atomically in `~/Library/Application Support/WordTail/vertical_offsets.json`
/// (with one-time migration and mirroring to `UserDefaults`) and merges across Macs via Last-Write-Wins
/// sync shards with hardware display keys and deletion tombstones.
public final class VerticalOffsetStore {
    public static let globalOffsetDefaultsKey = "WordTailGlobalVerticalOffset"
    public static let perAppOffsetsDefaultsKey = "WordTailPerAppVerticalOffsets"
    public static let perDisplayOffsetsDefaultsKey = "WordTailPerDisplayVerticalOffsets"
    public static let allowedRange: ClosedRange<Double> = -5.0...5.0
    public static let sliderRange: ClosedRange<Double> = -4.0...4.0
    public static let stepIncrement: Double = 0.05

    public struct OffsetEntry: Codable, Equatable, Sendable {
        public var value: Double
        public var updatedAt: TimeInterval
        public var isDeleted: Bool

        public init(value: Double, updatedAt: TimeInterval = 0, isDeleted: Bool = false) {
            self.value = value
            self.updatedAt = updatedAt
            self.isDeleted = isDeleted
        }
    }

    public struct SyncShard: Codable, Equatable, Sendable {
        public var globalOffset: OffsetEntry?
        public var perAppOffsets: [String: OffsetEntry]
        public var perDisplayAppOffsets: [String: OffsetEntry]

        public init(
            globalOffset: OffsetEntry? = nil,
            perAppOffsets: [String: OffsetEntry] = [:],
            perDisplayAppOffsets: [String: OffsetEntry] = [:]
        ) {
            self.globalOffset = globalOffset
            self.perAppOffsets = perAppOffsets
            self.perDisplayAppOffsets = perDisplayAppOffsets
        }
    }

    private struct PersistedDocument: Codable, Equatable {
        var schemaVersion: Int = 1
        var globalOffset: OffsetEntry?
        var perAppOffsets: [String: OffsetEntry] = [:]
        var perDisplayAppOffsets: [String: OffsetEntry] = [:]
    }

    private let defaults: UserDefaults
    private let fileURL: URL?
    private let lock = NSLock()
    private var document: PersistedDocument

    public init(fileURL: URL? = nil, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let fileURL {
            self.fileURL = fileURL
        } else if defaults === UserDefaults.standard {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Library/Application Support", isDirectory: true)
            self.fileURL = appSupport
                .appendingPathComponent("WordTail", isDirectory: true)
                .appendingPathComponent("vertical_offsets.json")
        } else {
            self.fileURL = nil
        }

        self.document = PersistedDocument()
        if let resolvedURL = self.fileURL {
            loadOrMigrateLocked(at: resolvedURL)
        }
    }

    public static func sanitize(_ value: Double) -> Double {
        guard value.isFinite else {
            return Double(ScreenGeometry.defaultVerticalOffset)
        }
        let clamped = min(max(value, allowedRange.lowerBound), allowedRange.upperBound)
        let stepped = (clamped / stepIncrement).rounded() * stepIncrement
        let cleaned = (stepped * 100.0).rounded() / 100.0
        return cleaned == 0 ? 0.0 : cleaned
    }

    /// Builds a stable hardware-backed display key that survives macOS CGDirectDisplayID renumbering across reboots/docks.
    public static func displayKey(
        isBuiltin: Bool,
        vendor: UInt32,
        model: UInt32,
        serial: UInt32,
        localizedName: String,
        scale: Double
    ) -> String {
        let safeScale = (scale.isFinite && scale > 0) ? scale : 2.0
        let scaleTag: String
        if abs(safeScale - safeScale.rounded()) < 0.01 {
            scaleTag = "\(Int(safeScale.rounded()))x"
        } else {
            scaleTag = String(format: "%.1fx", safeScale)
        }

        if isBuiltin {
            if vendor != 0 || model != 0 {
                return String(format: "builtin:%04x-%04x@%@", vendor, model, scaleTag)
            }
            return "builtin@\(scaleTag)"
        }

        if vendor != 0 || model != 0 {
            if serial != 0 {
                return String(format: "ext:%04x-%04x-%u@%@", vendor, model, serial, scaleTag)
            }
            return String(format: "ext:%04x-%04x@%@", vendor, model, scaleTag)
        }

        let lowered = localizedName.lowercased()
        var slug = ""
        var prevDash = false
        for scalar in lowered.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar), scalar.isASCII {
                slug.unicodeScalars.append(scalar)
                prevDash = false
            } else if !prevDash && !slug.isEmpty {
                slug.append("-")
                prevDash = true
            }
        }
        while slug.last == "-" {
            slug.removeLast()
        }
        let safeName = slug.isEmpty ? "unknown" : slug
        return "display:\(safeName)@\(scaleTag)"
    }

    public static func displayScopedKey(bundleID: String, displayKey: String) -> String {
        "\(bundleID)@\(displayKey)"
    }

    public static func parseDisplayScopedKey(_ raw: String) -> (bundleID: String, displayKey: String)? {
        guard let splitIdx = raw.firstIndex(of: "@") else { return nil }
        let bundleID = String(raw[..<splitIdx])
        let displayKey = String(raw[raw.index(after: splitIdx)...])
        guard !bundleID.isEmpty, !displayKey.isEmpty else { return nil }
        return (bundleID, displayKey)
    }

    /// Chooses the target application for menu bar calibration controls while ignoring desktop `com.apple.finder`
    /// clicks unless Finder genuinely owns an active editable text input.
    public static func resolveCalibrationTarget(
        focusedApp: CalibrationAppInfo?,
        focusedElementIsEditableText: Bool,
        frontmostApp: CalibrationAppInfo?,
        recentTypedApp: CalibrationAppInfo?,
        lastNonFinderApp: CalibrationAppInfo?,
        selfBundleID: String
    ) -> CalibrationAppInfo? {
        func isValidCandidate(_ app: CalibrationAppInfo?) -> CalibrationAppInfo? {
            guard let app, !app.bundleID.isEmpty, app.bundleID != selfBundleID else {
                return nil
            }
            return app
        }

        func isNonEditableFinder(_ app: CalibrationAppInfo) -> Bool {
            app.bundleID == "com.apple.finder" && !focusedElementIsEditableText
        }

        func attachDisplayIfMatching(_ app: CalibrationAppInfo) -> CalibrationAppInfo {
            guard app.displayKey == nil,
                  let recent = isValidCandidate(recentTypedApp),
                  recent.bundleID == app.bundleID,
                  recent.displayKey != nil else {
                return app
            }
            return CalibrationAppInfo(
                name: app.name,
                bundleID: app.bundleID,
                displayKey: recent.displayKey,
                displayName: recent.displayName
            )
        }

        if let focused = isValidCandidate(focusedApp), !isNonEditableFinder(focused) {
            return attachDisplayIfMatching(focused)
        }
        if let frontmost = isValidCandidate(frontmostApp), !isNonEditableFinder(frontmost) {
            return attachDisplayIfMatching(frontmost)
        }
        if let recent = isValidCandidate(recentTypedApp) {
            return recent
        }
        if let nonFinder = isValidCandidate(lastNonFinderApp) {
            return attachDisplayIfMatching(nonFinder)
        }
        return isValidCandidate(focusedApp) ?? isValidCandidate(frontmostApp)
    }

    public var globalOffset: Double {
        get {
            lock.lock()
            defer { lock.unlock() }
            return globalOffsetLocked()
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            let sanitized = Self.sanitize(newValue)
            if fileURL != nil {
                let prev = document.globalOffset?.updatedAt ?? 0
                let ts = max(Date().timeIntervalSince1970, prev.nextUp)
                document.globalOffset = OffsetEntry(value: sanitized, updatedAt: ts, isDeleted: false)
                _ = saveAtomicAndMirrorLocked()
            } else {
                defaults.set(sanitized, forKey: Self.globalOffsetDefaultsKey)
            }
        }
    }

    public func savedPerAppOffsets() -> [String: Double] {
        lock.lock()
        defer { lock.unlock() }
        return savedPerAppOffsetsLocked()
    }

    public func savedPerDisplayOffsets(forDisplayKey displayKey: String) -> [String: Double] {
        guard !displayKey.isEmpty else { return [:] }
        lock.lock()
        defer { lock.unlock() }
        return savedPerDisplayOffsetsLocked(forDisplayKey: displayKey)
    }

    public func allSavedDisplayKeys() -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        var keys = Set<String>()
        for (rawKey, entry) in allPerDisplayEntriesLocked() where !entry.isDeleted {
            if let parsed = Self.parseDisplayScopedKey(rawKey) {
                keys.insert(parsed.displayKey)
            }
        }
        return keys
    }

    public func hasDisplaySpecificOverride(forBundleID bundleID: String, displayKey: String) -> Bool {
        guard !bundleID.isEmpty, !displayKey.isEmpty else { return false }
        lock.lock()
        defer { lock.unlock() }
        return savedPerDisplayOffsetsLocked(forDisplayKey: displayKey)[bundleID] != nil
    }

    public func hasAnyDisplayOverride(forBundleID bundleID: String) -> Bool {
        guard !bundleID.isEmpty else { return false }
        lock.lock()
        defer { lock.unlock() }
        for (rawKey, entry) in allPerDisplayEntriesLocked() where !entry.isDeleted {
            if let parsed = Self.parseDisplayScopedKey(rawKey), parsed.bundleID == bundleID {
                return true
            }
        }
        return false
    }

    public func mergedAppOffsets(forDisplayKey displayKey: String? = nil) -> [String: Double] {
        lock.lock()
        defer { lock.unlock() }
        var merged: [String: Double] = [:]
        for (bundleID, val) in ScreenGeometry.builtInAppVerticalOffsets {
            merged[bundleID] = Self.sanitize(Double(val))
        }
        for (bundleID, val) in savedPerAppOffsetsLocked() {
            merged[bundleID] = val
        }
        if let displayKey, !displayKey.isEmpty {
            for (bundleID, val) in savedPerDisplayOffsetsLocked(forDisplayKey: displayKey) {
                merged[bundleID] = val
            }
        }
        return merged
    }

    public func customOffset(forBundleID bundleID: String, displayKey: String? = nil) -> Double? {
        lock.lock()
        defer { lock.unlock() }
        return customOffsetLocked(forBundleID: bundleID, displayKey: displayKey)
    }

    public func effectiveOffset(forBundleID bundleID: String?, displayKey: String? = nil) -> Double {
        lock.lock()
        defer { lock.unlock() }
        return effectiveOffsetLocked(forBundleID: bundleID, displayKey: displayKey)
    }

    @discardableResult
    public func setOffset(_ value: Double?, forBundleID bundleID: String, displayKey: String? = nil) -> Double? {
        guard !bundleID.isEmpty else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return setOffsetLocked(value, forBundleID: bundleID, displayKey: displayKey)
    }

    @discardableResult
    public func nudge(forBundleID bundleID: String, delta: Double, displayKey: String? = nil) -> Double {
        lock.lock()
        defer { lock.unlock() }

        let current = effectiveOffsetLocked(forBundleID: bundleID, displayKey: displayKey)
        guard !bundleID.isEmpty, delta.isFinite else {
            return current
        }
        let next = Self.sanitize(current + delta)
        return setOffsetLocked(next, forBundleID: bundleID, displayKey: displayKey) ?? next
    }

    @discardableResult
    public func resetGlobalOffset() -> Double {
        let defaultVal = Self.sanitize(Double(ScreenGeometry.defaultVerticalOffset))
        lock.lock()
        defer { lock.unlock() }
        if fileURL != nil {
            let prev = document.globalOffset?.updatedAt ?? 0
            let ts = max(Date().timeIntervalSince1970, prev.nextUp)
            document.globalOffset = OffsetEntry(value: defaultVal, updatedAt: ts, isDeleted: false)
            _ = saveAtomicAndMirrorLocked()
        } else {
            defaults.set(defaultVal, forKey: Self.globalOffsetDefaultsKey)
        }
        return defaultVal
    }

    public func removeOrReset(bundleID: String, displayKey: String? = nil) {
        setOffset(nil, forBundleID: bundleID, displayKey: displayKey)
    }

    public func exportLocalShard() -> SyncShard {
        lock.lock()
        defer { lock.unlock() }
        if fileURL != nil {
            return SyncShard(
                globalOffset: document.globalOffset,
                perAppOffsets: document.perAppOffsets,
                perDisplayAppOffsets: document.perDisplayAppOffsets
            )
        }
        var perApp: [String: OffsetEntry] = [:]
        for (bundleID, value) in savedPerAppOffsetsLocked() {
            perApp[bundleID] = OffsetEntry(value: value, updatedAt: 0, isDeleted: false)
        }
        var perDisplay: [String: OffsetEntry] = [:]
        for (rawKey, entry) in allPerDisplayEntriesLocked() {
            perDisplay[rawKey] = entry
        }
        let globalEntry = defaults.object(forKey: Self.globalOffsetDefaultsKey).flatMap {
            Self.numericDouble(from: $0).map { OffsetEntry(value: Self.sanitize($0), updatedAt: 0, isDeleted: false) }
        }
        return SyncShard(globalOffset: globalEntry, perAppOffsets: perApp, perDisplayAppOffsets: perDisplay)
    }

    @discardableResult
    public func applyRemoteShards(_ shards: [String: SyncShard]) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        var next = document
        if fileURL == nil {
            if let rawGlobal = defaults.object(forKey: Self.globalOffsetDefaultsKey),
               let num = Self.numericDouble(from: rawGlobal) {
                next.globalOffset = OffsetEntry(value: Self.sanitize(num), updatedAt: 0, isDeleted: false)
            }
            for (bundleID, val) in savedPerAppOffsetsLocked() {
                next.perAppOffsets[bundleID] = OffsetEntry(value: val, updatedAt: 0, isDeleted: false)
            }
            for (rawKey, entry) in allPerDisplayEntriesLocked() {
                next.perDisplayAppOffsets[rawKey] = entry
            }
        }

        var changed = false

        for shard in shards.values {
            if let incomingGlobal = shard.globalOffset,
               incomingGlobal.updatedAt.isFinite,
               incomingGlobal.value.isFinite {
                let sanitizedEntry = OffsetEntry(
                    value: Self.sanitize(incomingGlobal.value),
                    updatedAt: incomingGlobal.updatedAt,
                    isDeleted: incomingGlobal.isDeleted
                )
                if let existing = next.globalOffset {
                    if Self.isNewer(sanitizedEntry, than: existing) {
                        next.globalOffset = sanitizedEntry
                        changed = true
                    }
                } else {
                    next.globalOffset = sanitizedEntry
                    changed = true
                }
            }

            for (bundleID, incoming) in shard.perAppOffsets {
                guard !bundleID.isEmpty, incoming.updatedAt.isFinite, incoming.value.isFinite else { continue }
                let sanitizedEntry = OffsetEntry(
                    value: Self.sanitize(incoming.value),
                    updatedAt: incoming.updatedAt,
                    isDeleted: incoming.isDeleted
                )
                if let existing = next.perAppOffsets[bundleID] {
                    if Self.isNewer(sanitizedEntry, than: existing) {
                        next.perAppOffsets[bundleID] = sanitizedEntry
                        changed = true
                    }
                } else {
                    next.perAppOffsets[bundleID] = sanitizedEntry
                    changed = true
                }
            }

            for (rawKey, incoming) in shard.perDisplayAppOffsets {
                guard Self.parseDisplayScopedKey(rawKey) != nil,
                      incoming.updatedAt.isFinite,
                      incoming.value.isFinite else {
                    continue
                }
                let sanitizedEntry = OffsetEntry(
                    value: Self.sanitize(incoming.value),
                    updatedAt: incoming.updatedAt,
                    isDeleted: incoming.isDeleted
                )
                if let existing = next.perDisplayAppOffsets[rawKey] {
                    if Self.isNewer(sanitizedEntry, than: existing) {
                        next.perDisplayAppOffsets[rawKey] = sanitizedEntry
                        changed = true
                    }
                } else {
                    next.perDisplayAppOffsets[rawKey] = sanitizedEntry
                    changed = true
                }
            }
        }

        guard changed else { return true }
        document = next
        if fileURL != nil {
            return saveAtomicAndMirrorLocked()
        } else {
            mirrorDocumentToDefaultsLocked(next)
            return true
        }
    }

    // MARK: - Private Helpers

    private func loadOrMigrateLocked(at url: URL) {
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(PersistedDocument.self, from: data) {
            var sanitizedDoc = PersistedDocument(schemaVersion: decoded.schemaVersion)
            if let g = decoded.globalOffset, g.updatedAt.isFinite, g.value.isFinite {
                sanitizedDoc.globalOffset = OffsetEntry(
                    value: Self.sanitize(g.value),
                    updatedAt: g.updatedAt,
                    isDeleted: g.isDeleted
                )
            }
            for (bundleID, entry) in decoded.perAppOffsets where !bundleID.isEmpty && entry.updatedAt.isFinite && entry.value.isFinite {
                sanitizedDoc.perAppOffsets[bundleID] = OffsetEntry(
                    value: Self.sanitize(entry.value),
                    updatedAt: entry.updatedAt,
                    isDeleted: entry.isDeleted
                )
            }
            for (rawKey, entry) in decoded.perDisplayAppOffsets where Self.parseDisplayScopedKey(rawKey) != nil && entry.updatedAt.isFinite && entry.value.isFinite {
                sanitizedDoc.perDisplayAppOffsets[rawKey] = OffsetEntry(
                    value: Self.sanitize(entry.value),
                    updatedAt: entry.updatedAt,
                    isDeleted: entry.isDeleted
                )
            }
            document = sanitizedDoc
            mirrorDocumentToDefaultsLocked(sanitizedDoc)
            return
        }

        // One-time migration from legacy UserDefaults store.
        let now = Date().timeIntervalSince1970
        var migrated = PersistedDocument()
        if let rawGlobal = defaults.object(forKey: Self.globalOffsetDefaultsKey),
           let num = Self.numericDouble(from: rawGlobal) {
            migrated.globalOffset = OffsetEntry(value: Self.sanitize(num), updatedAt: now, isDeleted: false)
        }
        if let rawDict = defaults.dictionary(forKey: Self.perAppOffsetsDefaultsKey) {
            for (bundleID, rawVal) in rawDict where !bundleID.isEmpty {
                if let num = Self.numericDouble(from: rawVal) {
                    migrated.perAppOffsets[bundleID] = OffsetEntry(value: Self.sanitize(num), updatedAt: now, isDeleted: false)
                }
            }
        }
        document = migrated
        _ = saveAtomicAndMirrorLocked()
    }

    private func saveAtomicAndMirrorLocked() -> Bool {
        mirrorDocumentToDefaultsLocked(document)
        guard let url = fileURL else { return true }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(document)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    private func mirrorDocumentToDefaultsLocked(_ doc: PersistedDocument) {
        if let g = doc.globalOffset, !g.isDeleted {
            defaults.set(Self.sanitize(g.value), forKey: Self.globalOffsetDefaultsKey)
        } else {
            defaults.removeObject(forKey: Self.globalOffsetDefaultsKey)
        }
        var perAppMirror: [String: Double] = [:]
        for (bundleID, entry) in doc.perAppOffsets where !entry.isDeleted {
            perAppMirror[bundleID] = Self.sanitize(entry.value)
        }
        defaults.set(perAppMirror, forKey: Self.perAppOffsetsDefaultsKey)

        if fileURL == nil {
            var perDisplayMirror: [String: Double] = [:]
            for (rawKey, entry) in doc.perDisplayAppOffsets where !entry.isDeleted {
                perDisplayMirror[rawKey] = Self.sanitize(entry.value)
            }
            defaults.set(perDisplayMirror, forKey: Self.perDisplayOffsetsDefaultsKey)
        }
    }

    private func setOffsetLocked(_ value: Double?, forBundleID bundleID: String, displayKey: String?) -> Double? {
        let now = Date().timeIntervalSince1970
        let scopedKey = (displayKey.flatMap { $0.isEmpty ? nil : Self.displayScopedKey(bundleID: bundleID, displayKey: $0) })

        if fileURL != nil {
            if let scopedKey {
                let prev = document.perDisplayAppOffsets[scopedKey]?.updatedAt ?? 0
                let ts = max(now, prev.nextUp)
                if let value {
                    let sanitized = Self.sanitize(value)
                    document.perDisplayAppOffsets[scopedKey] = OffsetEntry(value: sanitized, updatedAt: ts, isDeleted: false)
                    _ = saveAtomicAndMirrorLocked()
                    return sanitized
                } else {
                    let preservedValue = document.perDisplayAppOffsets[scopedKey]?.value ?? 0.0
                    document.perDisplayAppOffsets[scopedKey] = OffsetEntry(value: preservedValue, updatedAt: ts, isDeleted: true)
                    _ = saveAtomicAndMirrorLocked()
                    return nil
                }
            } else {
                let prev = document.perAppOffsets[bundleID]?.updatedAt ?? 0
                let ts = max(now, prev.nextUp)
                if let value {
                    let sanitized = Self.sanitize(value)
                    document.perAppOffsets[bundleID] = OffsetEntry(value: sanitized, updatedAt: ts, isDeleted: false)
                    _ = saveAtomicAndMirrorLocked()
                    return sanitized
                } else {
                    let preservedValue = document.perAppOffsets[bundleID]?.value ?? 0.0
                    document.perAppOffsets[bundleID] = OffsetEntry(value: preservedValue, updatedAt: ts, isDeleted: true)
                    _ = saveAtomicAndMirrorLocked()
                    return nil
                }
            }
        } else {
            if let scopedKey {
                var dict = (defaults.dictionary(forKey: Self.perDisplayOffsetsDefaultsKey) as? [String: Double]) ?? [:]
                let stored: Double?
                if let value {
                    let sanitized = Self.sanitize(value)
                    dict[scopedKey] = sanitized
                    stored = sanitized
                } else {
                    dict.removeValue(forKey: scopedKey)
                    stored = nil
                }
                defaults.set(dict, forKey: Self.perDisplayOffsetsDefaultsKey)
                return stored
            } else {
                var dict = savedPerAppOffsetsLocked()
                let stored: Double?
                if let value {
                    let sanitized = Self.sanitize(value)
                    dict[bundleID] = sanitized
                    stored = sanitized
                } else {
                    dict.removeValue(forKey: bundleID)
                    stored = nil
                }
                defaults.set(dict, forKey: Self.perAppOffsetsDefaultsKey)
                return stored
            }
        }
    }

    private func globalOffsetLocked() -> Double {
        if fileURL != nil {
            if let entry = document.globalOffset, !entry.isDeleted, entry.value.isFinite {
                return Self.sanitize(entry.value)
            }
            return Double(ScreenGeometry.defaultVerticalOffset)
        }
        guard let raw = defaults.object(forKey: Self.globalOffsetDefaultsKey) else {
            return Double(ScreenGeometry.defaultVerticalOffset)
        }
        if let num = Self.numericDouble(from: raw) {
            return Self.sanitize(num)
        }
        return Double(ScreenGeometry.defaultVerticalOffset)
    }

    private func savedPerAppOffsetsLocked() -> [String: Double] {
        if fileURL != nil {
            var result: [String: Double] = [:]
            result.reserveCapacity(document.perAppOffsets.count)
            for (bundleID, entry) in document.perAppOffsets where !bundleID.isEmpty && !entry.isDeleted && entry.value.isFinite {
                result[bundleID] = Self.sanitize(entry.value)
            }
            return result
        }
        guard let rawDict = defaults.dictionary(forKey: Self.perAppOffsetsDefaultsKey) else {
            return [:]
        }
        var result: [String: Double] = [:]
        result.reserveCapacity(rawDict.count)
        for (bundleID, rawVal) in rawDict where !bundleID.isEmpty {
            if let num = Self.numericDouble(from: rawVal) {
                result[bundleID] = Self.sanitize(num)
            }
        }
        return result
    }

    private func allPerDisplayEntriesLocked() -> [String: OffsetEntry] {
        if fileURL != nil {
            return document.perDisplayAppOffsets
        }
        guard let rawDict = defaults.dictionary(forKey: Self.perDisplayOffsetsDefaultsKey) else {
            return [:]
        }
        var result: [String: OffsetEntry] = [:]
        for (rawKey, rawVal) in rawDict where Self.parseDisplayScopedKey(rawKey) != nil {
            if let num = Self.numericDouble(from: rawVal) {
                result[rawKey] = OffsetEntry(value: Self.sanitize(num), updatedAt: 0, isDeleted: false)
            }
        }
        return result
    }

    private func savedPerDisplayOffsetsLocked(forDisplayKey displayKey: String) -> [String: Double] {
        var result: [String: Double] = [:]
        for (rawKey, entry) in allPerDisplayEntriesLocked() where !entry.isDeleted && entry.value.isFinite {
            if let parsed = Self.parseDisplayScopedKey(rawKey), parsed.displayKey == displayKey {
                result[parsed.bundleID] = Self.sanitize(entry.value)
            }
        }
        return result
    }

    private func customOffsetLocked(forBundleID bundleID: String, displayKey: String? = nil) -> Double? {
        if let displayKey, !displayKey.isEmpty,
           let displayVal = savedPerDisplayOffsetsLocked(forDisplayKey: displayKey)[bundleID] {
            return displayVal
        }
        if let saved = savedPerAppOffsetsLocked()[bundleID] {
            return saved
        }
        if let builtIn = ScreenGeometry.builtInAppVerticalOffsets[bundleID] {
            return Self.sanitize(Double(builtIn))
        }
        return nil
    }

    private func effectiveOffsetLocked(forBundleID bundleID: String?, displayKey: String? = nil) -> Double {
        if let bundleID, let custom = customOffsetLocked(forBundleID: bundleID, displayKey: displayKey) {
            return custom
        }
        return globalOffsetLocked()
    }

    private static func isNewer(_ incoming: OffsetEntry, than existing: OffsetEntry) -> Bool {
        if incoming.updatedAt != existing.updatedAt {
            return incoming.updatedAt > existing.updatedAt
        }
        if incoming.isDeleted != existing.isDeleted {
            return incoming.isDeleted
        }
        guard incoming != existing else { return false }
        return incoming.value > existing.value
    }

    private static func numericDouble(from raw: Any) -> Double? {
        if CFGetTypeID(raw as AnyObject) == CFBooleanGetTypeID() {
            return nil
        }
        if let d = raw as? Double {
            return d
        }
        if let num = raw as? NSNumber {
            return num.doubleValue
        }
        return nil
    }
}
