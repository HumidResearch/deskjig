import Foundation

public enum LogLevel: Int, Comparable, Sendable {
    case trace = 0
    case debug = 1
    case info = 2
    case warn = 3
    case error = 4

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public final class SubsystemRegistry: @unchecked Sendable {
    public static let shared = SubsystemRegistry()

    private let lock = NSLock()
    private var overrides: [LogSubsystem: LogLevel] = [:]
    private var cachedEnvVerbose: Set<String>?  // lazy-parsed from BENTO_LOG_VERBOSE

    private init() {
        parseEnvironment()
    }

    /// Check if message at given level should be emitted for subsystem
    public func shouldLog(_ level: LogLevel, for subsystem: LogSubsystem) -> Bool {
        level >= effectiveLevel(for: subsystem)
    }

    public func effectiveLevel(for subsystem: LogSubsystem) -> LogLevel {
        // 1. Check per-subsystem env var: BENTO_LOG_LEVEL_restore_executor=trace
        //    (legacy BENTO_* env names are kept — documented in LEGACY_IDENTIFIERS.md)
        let envKey = "BENTO_LOG_LEVEL_\(subsystem.rawValue.replacingOccurrences(of: ".", with: "_"))"
        if let envValue = ProcessInfo.processInfo.environment[envKey],
           let level = parseLogLevel(envValue) {
            return level
        }

        // 2. Check BENTO_LOG_VERBOSE wildcard env var
        if let verbose = cachedEnvVerbose,
           Self.matchesVerbose(subsystem, verbose: verbose) {
            return .trace
        }

        // 3. Check UserDefaults override (legacy key prefix — set on existing installs)
        let udKey = "bento.logLevel.\(subsystem.rawValue)"
        if let udValue = UserDefaults.standard.string(forKey: udKey),
           let level = parseLogLevel(udValue) {
            return level
        }

        // 4. Check verbose logging toggle (sets everything to debug)
        if UserDefaults.standard.bool(forKey: "bento.traceLogging.enabled") {
            return .debug
        }

        // 5. Check runtime API overrides
        lock.lock()
        let override = overrides[subsystem]
        lock.unlock()
        if let override { return override }

        // 6. Return default for build config
        return defaultLevel(for: subsystem)
    }

    static func matchesVerbose(_ subsystem: LogSubsystem, verbose: Set<String>) -> Bool {
        let name = subsystem.rawValue
        if verbose.contains(name) || verbose.contains("*") {
            return true
        }

        return verbose.contains { pattern in
            guard pattern.hasSuffix(".*") else { return false }
            let prefix = String(pattern.dropLast(2))
            return name == prefix || name.hasPrefix(prefix + ".")
        }
    }

    public func setLevel(_ level: LogLevel, for subsystem: LogSubsystem) {
        lock.lock()
        overrides[subsystem] = level
        lock.unlock()
    }

    private func defaultLevel(for subsystem: LogSubsystem) -> LogLevel {
        #if DEBUG
        switch subsystem.category {
        case "restore": return .debug
        case "tmux", "terminal": return .debug
        case "chrome": return .debug
        case "cli": return .debug
        case "window": return .info
        case "workspace": return .info
        case "app": return .info
        default: return .info
        }
        #else
        switch subsystem.category {
        case "restore": return .info
        case "window": return .warn
        case "workspace": return .warn
        case "cli": return .info
        case "app": return .info
        default: return .info
        }
        #endif
    }

    private func parseEnvironment() {
        if let verbose = ProcessInfo.processInfo.environment["BENTO_LOG_VERBOSE"], !verbose.isEmpty {
            cachedEnvVerbose = Set(verbose.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        }
    }

    private func parseLogLevel(_ string: String) -> LogLevel? {
        switch string.lowercased() {
        case "trace": return .trace
        case "debug": return .debug
        case "info": return .info
        case "warn", "warning": return .warn
        case "error": return .error
        default: return nil
        }
    }
}
