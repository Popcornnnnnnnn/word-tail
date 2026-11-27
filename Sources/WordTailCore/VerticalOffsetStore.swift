import Foundation

/// Single source of truth for WordTail's vertical ghost-text baseline calibration offsets.
///
/// Calibration values stay strictly local to each Mac and are sanitized uniformly across
/// Settings, the menu bar popover, and the context menu.
public final class VerticalOffsetStore {
    public static let globalOffsetDefaultsKey = "WordTailGlobalVerticalOffset"
    public static let perAppOffsetsDefaultsKey = "WordTailPerAppVerticalOffsets"
    public static let allowedRange: ClosedRange<Double> = -5.0...5.0
    public static let sliderRange: ClosedRange<Double> = -4.0...4.0
    public static let stepIncrement: Double = 0.05

    private let defaults: UserDefaults
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
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

    public var globalOffset: Double {
        get {
            lock.lock()
            defer { lock.unlock() }
            return globalOffsetLocked()
        }
        set {
            lock.lock()
            defaults.set(Self.sanitize(newValue), forKey: Self.globalOffsetDefaultsKey)
            lock.unlock()
        }
    }

    public func savedPerAppOffsets() -> [String: Double] {
        lock.lock()
        defer { lock.unlock() }
        return savedPerAppOffsetsLocked()
    }

    public func mergedAppOffsets() -> [String: Double] {
        lock.lock()
        defer { lock.unlock() }
        var merged: [String: Double] = [:]
        for (bundleID, val) in ScreenGeometry.builtInAppVerticalOffsets {
            merged[bundleID] = Self.sanitize(Double(val))
        }
        for (bundleID, val) in savedPerAppOffsetsLocked() {
            merged[bundleID] = val
        }
        return merged
    }

    public func customOffset(forBundleID bundleID: String) -> Double? {
        lock.lock()
        defer { lock.unlock() }
        return customOffsetLocked(forBundleID: bundleID)
    }

    public func effectiveOffset(forBundleID bundleID: String?) -> Double {
        lock.lock()
        defer { lock.unlock() }
        return effectiveOffsetLocked(forBundleID: bundleID)
    }

    @discardableResult
    public func setOffset(_ value: Double?, forBundleID bundleID: String) -> Double? {
        guard !bundleID.isEmpty else { return nil }
        lock.lock()
        defer { lock.unlock() }

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

    @discardableResult
    public func nudge(forBundleID bundleID: String, delta: Double) -> Double {
        lock.lock()
        defer { lock.unlock() }

        let current = effectiveOffsetLocked(forBundleID: bundleID)
        guard !bundleID.isEmpty, delta.isFinite else {
            return current
        }
        let next = Self.sanitize(current + delta)
        var dict = savedPerAppOffsetsLocked()
        dict[bundleID] = next
        defaults.set(dict, forKey: Self.perAppOffsetsDefaultsKey)
        return next
    }

    @discardableResult
    public func resetGlobalOffset() -> Double {
        let defaultVal = Self.sanitize(Double(ScreenGeometry.defaultVerticalOffset))
        lock.lock()
        defaults.set(defaultVal, forKey: Self.globalOffsetDefaultsKey)
        lock.unlock()
        return defaultVal
    }

    public func removeOrReset(bundleID: String) {
        setOffset(nil, forBundleID: bundleID)
    }

    private func globalOffsetLocked() -> Double {
        guard let raw = defaults.object(forKey: Self.globalOffsetDefaultsKey) else {
            return Double(ScreenGeometry.defaultVerticalOffset)
        }
        if let num = Self.numericDouble(from: raw) {
            return Self.sanitize(num)
        }
        return Double(ScreenGeometry.defaultVerticalOffset)
    }

    private func savedPerAppOffsetsLocked() -> [String: Double] {
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

    private func customOffsetLocked(forBundleID bundleID: String) -> Double? {
        if let saved = savedPerAppOffsetsLocked()[bundleID] {
            return saved
        }
        if let builtIn = ScreenGeometry.builtInAppVerticalOffsets[bundleID] {
            return Self.sanitize(Double(builtIn))
        }
        return nil
    }

    private func effectiveOffsetLocked(forBundleID bundleID: String?) -> Double {
        if let bundleID, let custom = customOffsetLocked(forBundleID: bundleID) {
            return custom
        }
        return globalOffsetLocked()
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
