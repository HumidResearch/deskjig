//
//  RestoreDebugLogView.swift
//  DeskJig
//
//  Real-time debug log display matching DeskJigLog format.
//  Shows restoration progress with syntax highlighting for phases.
//

import SwiftUI
import DeskJigShared

struct RestoreDebugLogView: View {
    @Bindable var strategyManager: LaunchStrategyManager
    @State private var autoScroll: Bool = true
    @State private var isHovering: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            headerSection

            Divider()

            // Log content
            if strategyManager.logEntries.isEmpty {
                emptyState
            } else {
                logContent
            }
        }
        .background(Color.black.opacity(0.3))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(DesignTokens.Surface.elevated, lineWidth: 1)
        )
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack {
            Text("Debug Log")
                .font(.subheadline)
                .fontWeight(.semibold)

            if strategyManager.isLaunching {
                ProgressView()
                    .scaleEffect(0.6)
                    .padding(.leading, 4)
            }

            // Run ID display with copy button
            if let runId = strategyManager.currentRunId {
                HStack(spacing: 4) {
                    Text("Run:")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(runId)
                        .font(brand: Font.brandBody(size: 10))
                        .foregroundStyle(.secondary)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(runId, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(brand: Font.brandBody(size: 9))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                    .help("Copy run ID")
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(DesignTokens.Brand.accent.opacity(0.1))
                .cornerRadius(4)
            }

            Spacer()

            // Filter field
            HStack(spacing: 4) {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                TextField("Filter...", text: $strategyManager.logFilter)
                    .textFieldStyle(.plain)
                    .font(.caption)
                    .frame(width: 80)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(DesignTokens.Surface.cardHover)
            .cornerRadius(4)

            Button {
                strategyManager.clearLog()
            } label: {
                Image(systemName: "trash")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Clear log")

            Button {
                copyLogToClipboard()
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Copy log to clipboard")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "text.alignleft")
                .font(.title2)
                .foregroundStyle(.tertiary)
            Text("No log entries")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Launch a workspace to see debug output")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, minHeight: 100)
        .padding()
    }

    // MARK: - Log Content

    private var logContent: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(strategyManager.filteredLogEntries) { entry in
                        LogEntryRow(entry: entry)
                            .id(entry.id)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
            .frame(minHeight: 150, maxHeight: 300)
            .onHover { hovering in
                isHovering = hovering
                if hovering {
                    autoScroll = false
                }
            }
            .onChange(of: strategyManager.logEntries.count) {
                if autoScroll, let lastEntry = strategyManager.logEntries.last {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(lastEntry.id, anchor: .bottom)
                    }
                }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if !autoScroll {
                Button {
                    autoScroll = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.down.to.line")
                        Text("Auto-scroll")
                    }
                    .font(.caption2)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(DesignTokens.Brand.accent.opacity(0.9))
                    .foregroundStyle(DesignTokens.Text.primary)
                    .cornerRadius(4)
                }
                .buttonStyle(.plain)
                .padding(8)
            }
        }
    }

    // MARK: - Actions

    private func copyLogToClipboard() {
        let text = strategyManager.exportLog()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - Log Entry Row

private struct LogEntryRow: View {
    let entry: DebugLogEntry
    @State private var isExpanded: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Main line
            HStack(spacing: 4) {
                // Phase badge
                Text(entry.phase.rawValue)
                    .font(brand: Font.brandBody(size: 9))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(entry.phaseColor.opacity(0.2))
                    .foregroundStyle(entry.phaseColor)
                    .cornerRadius(2)

                // Elapsed time
                Text(String(format: "+%.3fs", entry.elapsed))
                    .font(brand: Font.brandBody(size: 10))
                    .foregroundStyle(.tertiary)

                // Task ID (if present)
                if let taskId = entry.taskId {
                    Text("[\(taskId)]")
                        .font(brand: Font.brandBody(size: 10))
                        .foregroundStyle(.secondary)
                }

                // Message
                Text(entry.message)
                    .font(brand: Font.brandBody(size: 11))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer()

                // Expand button if has data
                if !entry.data.isEmpty {
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            isExpanded.toggle()
                        }
                    } label: {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(brand: Font.brandBody(size: 8))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 3)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
            .onTapGesture {
                if !entry.data.isEmpty {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isExpanded.toggle()
                    }
                }
            }

            // Expanded data
            if isExpanded && !entry.data.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(entry.data.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                        HStack(spacing: 4) {
                            Text(key + ":")
                                .font(brand: Font.brandBody(size: 10))
                                .foregroundStyle(.tertiary)
                            Text(value)
                                .font(brand: Font.brandBody(size: 10))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                }
                .padding(.leading, 24)
                .padding(.vertical, 4)
                .padding(.trailing, 8)
                .background(DesignTokens.Surface.card)
            }
        }
        .background(Color.clear)
    }
}

// MARK: - Preview

#Preview {
    let manager = LaunchStrategyManager()
    manager.startLaunch()
    manager.addLogEntry(phase: .start, message: "Beginning restoration", data: ["dryRun": "false"])
    manager.addLogEntry(phase: .launch, taskId: "cursor-0", message: "Launching Cursor", data: ["app": "Cursor", "method": "cli", "directory": "/Users/andrew/code/deskjig"])
    manager.addLogEntry(phase: .match, taskId: "cursor-0", message: "Matched Cursor window", data: ["confidence": "100%", "windowId": "12345", "found": "true"])
    manager.addLogEntry(phase: .position, taskId: "cursor-0", message: "Positioned window", data: ["success": "true", "targetX": "0", "targetY": "25"])
    manager.addLogEntry(phase: .chrome, taskId: "chrome-1", message: "Opening profile tabs", data: ["profile": "Default", "tabCount": "5"])

    return RestoreDebugLogView(strategyManager: manager)
        .frame(width: 600, height: 300)
        .padding()
}