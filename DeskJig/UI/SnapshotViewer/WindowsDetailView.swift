//
//  WindowsDetailView.swift
//  DeskJig
//
//  Detail view for Windows section - toolbar, filters, table, and inspector
//

import SwiftUI
import DeskJigShared

struct WindowsDetailView: View {
    @Bindable var viewModel: SnapshotViewerViewModel

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            toolbarView

            Divider()

            // Filter chips bar (shown when filters active)
            if !viewModel.activeFilterChips.isEmpty {
                FilterChipsBar(
                    chips: viewModel.activeFilterChips,
                    onRemove: { viewModel.removeFilter($0) },
                    onClearAll: { viewModel.filterState.clearAll() }
                )
                Divider()
            }

            // Windows table
            WindowsListView(viewModel: viewModel)
        }
        .inspector(isPresented: $viewModel.isInspectorPresented) {
            WindowDetailView(
                window: viewModel.selectedWindow,
                snapshot: viewModel.snapshot,
                onRefresh: { Task { await viewModel.captureSnapshot() } },
                onRefreshChrome: { await viewModel.refreshChromeCapture() }
            )
            .inspectorColumnWidth(min: 280, ideal: 320, max: 400)
        }
        .onAppear {
            viewModel.applyWindowOpacity()
        }
        .onDisappear {
            viewModel.stopLiveUpdates()
        }
        .onChange(of: viewModel.selectedWindowId) { oldValue, newValue in
            if let windowId = newValue,
               let window = viewModel.snapshot?.windows.first(where: { $0.id == windowId }) {
                WindowHighlightOverlay.shared.showHighlight(
                    around: window.frame,
                    duration: 2.5,
                    color: DesignTokens.Brand.accent,
                    lineWidth: 4.0
                )

                Task {
                    await viewModel.onWindowSelected(window)
                }
            }
        }
    }

    // MARK: - Toolbar

    private var toolbarView: some View {
        HStack {
            // Refresh button
            Button(action: { Task { await viewModel.captureSnapshot() } }) {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(viewModel.isCapturing || viewModel.isLiveUpdating)

            // Live updates toggle
            liveUpdatesToggle

            if viewModel.isCapturing {
                ProgressView()
                    .scaleEffect(0.6)
                    .frame(width: 16, height: 16)
            }

            Spacer()

            // Capture stats
            captureStatsView

            Divider()
                .frame(height: 20)

            // Chrome toggle button
            chromeToggle

            Divider()
                .frame(height: 20)

            // Filter controls button (opens popover)
            FilterControlsButton(viewModel: viewModel)

            Divider()
                .frame(height: 20)

            // Opacity slider
            opacitySlider
        }
        .padding()
    }

    private var opacitySlider: some View {
        HStack(spacing: 4) {
            Image(systemName: "eye.slash")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Slider(value: $viewModel.windowOpacity, in: 0.3...1.0)
                .frame(width: 60)
            Image(systemName: "eye")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .help("Window opacity: \(Int(viewModel.windowOpacity * 100))%")
    }

    private var liveUpdatesToggle: some View {
        Button(action: { viewModel.toggleLiveUpdates() }) {
            HStack(spacing: 4) {
                Image(systemName: viewModel.isLiveUpdating ? "pause.fill" : "play.fill")
                Text(viewModel.isLiveUpdating ? "Stop" : "Live")
            }
            .font(.caption)
        }
        .buttonStyle(.bordered)
        .tint(viewModel.isLiveUpdating ? DesignTokens.Brand.accent : DesignTokens.Brand.accent)
    }

    private var chromeToggle: some View {
        Button(action: { viewModel.shouldFetchChromeInfo.toggle() }) {
            HStack(spacing: 4) {
                Image(systemName: "globe")
                Text("Chrome")
            }
            .font(.caption)
        }
        .buttonStyle(.bordered)
        .tint(viewModel.shouldFetchChromeInfo ? DesignTokens.Brand.accent : .secondary)
        .help(viewModel.shouldFetchChromeInfo ? "Chrome tab data enabled" : "Enable Chrome tab data (slower)")
    }

    private var captureStatsView: some View {
        HStack(spacing: 8) {
            if let snapshot = viewModel.snapshot {
                Text("Captured in \(snapshot.captureDurationMs)ms")
                    .foregroundStyle(.secondary)
                    .font(.caption)

                if !snapshot.timing.isEmpty {
                    Text("(\(snapshot.timing.map { "\($0.key): \($0.value)ms" }.joined(separator: ", ")))")
                        .foregroundStyle(.tertiary)
                        .font(.caption2)
                }
            }

            // Chrome data staleness indicator
            if viewModel.isLiveUpdating {
                chromeStalenessIndicator
            }

            // Window picking hint
            windowPickingHint
        }
    }

    private var windowPickingHint: some View {
        HStack(spacing: 2) {
            Image(systemName: "cursorarrow.click")
                .font(.caption2)
            Text("\u{2318}\u{21E7}P")
                .font(.system(.caption2, design: .rounded))
        }
        .foregroundStyle(.tertiary)
        .help("Press \u{2318}\u{21E7}P to select the window under your cursor")
    }

    private var chromeStalenessIndicator: some View {
        HStack(spacing: 2) {
            Image(systemName: "globe")
                .font(.caption2)
            Text("Chrome: \(viewModel.chromeDataAgeText)")
                .font(.caption2)
        }
        .foregroundStyle(viewModel.isChromeDataStale ? DesignTokens.Brand.accent : .secondary)
        .help("Chrome tab data is updated every \(Int(viewModel.slowCaptureInterval))s")
    }
}