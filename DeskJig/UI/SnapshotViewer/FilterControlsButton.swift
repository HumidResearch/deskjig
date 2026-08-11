//
//  FilterControlsButton.swift
//  DeskJig
//
//  Toolbar button with popover for filter controls
//

import SwiftUI
import DeskJigShared

struct FilterControlsButton: View {
    @Bindable var viewModel: SnapshotViewerViewModel
    @State private var showPopover = false

    var body: some View {
        Button {
            showPopover.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "line.3.horizontal.decrease")
                if viewModel.filterState.activeFilterCount > 0 {
                    Text("\(viewModel.filterState.activeFilterCount)")
                        .font(.caption2)
                        .fontWeight(.medium)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Circle().fill(DesignTokens.Brand.accent))
                        .foregroundStyle(DesignTokens.Text.primary)
                }
            }
        }
        .help("Filter options")
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            FilterControlsPopover(viewModel: viewModel)
        }
    }
}

struct FilterControlsPopover: View {
    @Bindable var viewModel: SnapshotViewerViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Filter Windows")
                .font(.headline)

            Divider()

            // Search
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search...", text: $viewModel.filterState.searchText)
                    .textFieldStyle(.roundedBorder)
                if !viewModel.filterState.searchText.isEmpty {
                    Button {
                        viewModel.filterState.searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }

            Divider()

            // Visibility filter
            HStack {
                Text("Visibility")
                    .frame(width: 80, alignment: .leading)
                Spacer()
                Picker("", selection: $viewModel.filterState.onScreenOnly) {
                    Text("All").tag(nil as Bool?)
                    Text("On Screen").tag(true as Bool?)
                    Text("Off Screen").tag(false as Bool?)
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
            }

            // Minimized filter
            HStack {
                Text("Minimized")
                    .frame(width: 80, alignment: .leading)
                Spacer()
                Picker("", selection: $viewModel.filterState.minimizedOnly) {
                    Text("All").tag(nil as Bool?)
                    Text("Yes").tag(true as Bool?)
                    Text("No").tag(false as Bool?)
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
            }

            Divider()

            // Min size slider
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Minimum Size")
                    Spacer()
                    Text("\(Int(viewModel.filterState.minFrameSize))px")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: 50, alignment: .trailing)
                }
                HStack {
                    Text("0")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Slider(value: $viewModel.filterState.minFrameSize, in: 0...500, step: 10)
                    Text("500")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Text("Hide windows smaller than this width and height")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Divider()

            // Current filter summary
            if viewModel.filterState.hasActiveFilters {
                HStack {
                    Text("\(viewModel.filterState.activeFilterCount) filter\(viewModel.filterState.activeFilterCount == 1 ? "" : "s") active")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset All") {
                        viewModel.filterState.clearAll()
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
            } else {
                Text("No filters active")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding()
        .frame(width: 340)
    }
}

#Preview {
    FilterControlsButton(viewModel: SnapshotViewerViewModel())
        .padding()
}
