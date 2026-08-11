//
//  FilterState.swift
//  DeskJig
//
//  Filter state model and chip types for the Snapshot Viewer
//

import Foundation

// MARK: - Filter State

/// Represents all active filters for the window list
struct FilterState: Equatable {
    var selectedDisplayIndex: Int? = nil
    var searchText: String = ""
    var onScreenOnly: Bool? = nil        // nil = all, true = on screen, false = off screen
    var minimizedOnly: Bool? = nil       // nil = all, true = minimized, false = not minimized
    var minFrameSize: CGFloat = 0        // Hide windows smaller than this (width or height)
    var filterPid: pid_t? = nil          // Filter by specific PID
    var filterBundleId: String? = nil    // Filter by bundle ID
    var filterTitle: String? = nil       // Filter by exact title (from context menu)

    var hasActiveFilters: Bool {
        selectedDisplayIndex != nil ||
        !searchText.isEmpty ||
        onScreenOnly != nil ||
        minimizedOnly != nil ||
        minFrameSize > 0 ||
        filterPid != nil ||
        filterBundleId != nil ||
        filterTitle != nil
    }

    var activeFilterCount: Int {
        var count = 0
        if selectedDisplayIndex != nil { count += 1 }
        if !searchText.isEmpty { count += 1 }
        if onScreenOnly != nil { count += 1 }
        if minimizedOnly != nil { count += 1 }
        if minFrameSize > 0 { count += 1 }
        if filterPid != nil { count += 1 }
        if filterBundleId != nil { count += 1 }
        if filterTitle != nil { count += 1 }
        return count
    }

    mutating func clearAll() {
        selectedDisplayIndex = nil
        searchText = ""
        onScreenOnly = nil
        minimizedOnly = nil
        minFrameSize = 0
        filterPid = nil
        filterBundleId = nil
        filterTitle = nil
    }
}

// MARK: - Filter Chip

/// Represents a single filter chip for display in the filter bar
enum FilterChip: Identifiable, Equatable {
    case display(index: Int, name: String)
    case searchText(String)
    case onScreen(Bool)
    case minimized(Bool)
    case minSize(CGFloat)
    case pid(pid_t)
    case bundleId(String)
    case title(String)

    var id: String {
        switch self {
        case .display(let idx, _): return "display-\(idx)"
        case .searchText: return "search"
        case .onScreen: return "onscreen"
        case .minimized: return "minimized"
        case .minSize: return "minsize"
        case .pid(let p): return "pid-\(p)"
        case .bundleId(let b): return "bundle-\(b)"
        case .title: return "title"
        }
    }

    var label: String {
        switch self {
        case .display(_, let name): return "Display: \(name)"
        case .searchText(let text): return "Search: \"\(text)\""
        case .onScreen(let value): return value ? "On Screen" : "Off Screen"
        case .minimized(let value): return value ? "Minimized" : "Not Minimized"
        case .minSize(let size): return "Size >= \(Int(size))px"
        case .pid(let p): return "PID: \(p)"
        case .bundleId(let b):
            let shortName = b.split(separator: ".").last ?? Substring(b)
            return "App: \(shortName)"
        case .title(let t):
            let truncated = t.prefix(20)
            return "Title: \"\(truncated)\(t.count > 20 ? "..." : "")\""
        }
    }

    var icon: String {
        switch self {
        case .display: return "display"
        case .searchText: return "magnifyingglass"
        case .onScreen(let value): return value ? "eye.fill" : "eye.slash"
        case .minimized(let value): return value ? "minus.circle.fill" : "minus.circle"
        case .minSize: return "aspectratio"
        case .pid: return "number"
        case .bundleId: return "app.badge"
        case .title: return "textformat"
        }
    }
}