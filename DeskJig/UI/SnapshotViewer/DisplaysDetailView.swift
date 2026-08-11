//
//  DisplaysDetailView.swift
//  DeskJig
//
//  Detail view for Displays section - display arrangement, info, and cache data
//

import SwiftUI
import DeskJigShared

struct DisplaysDetailView: View {
    @Bindable var viewModel: SnapshotViewerViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Display arrangement visual
                displayArrangementSection

                Divider()

                // Display list
                displayListSection

                Spacer()
            }
            .padding()
        }
    }

    // MARK: - Display Arrangement Section

    @ViewBuilder
    private var displayArrangementSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Display Arrangement")
                .font(.headline)

            if let snapshot = viewModel.snapshot, !snapshot.displays.isEmpty {
                displayArrangementView(displays: snapshot.displays)
            } else {
                Text("No displays detected")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 100)
                    .background(DesignTokens.Surface.cardHover)
                    .cornerRadius(8)
            }
        }
    }

    private func displayArrangementView(displays: [DisplayInfo]) -> some View {
        let items = displays.map { display in
            let displayName = display.name ?? "Display \(display.index)"
            return DSDisplayArrangementItem(
                id: "\(display.index)",
                frame: display.frame,
                title: displayName,
                subtitle: "\(Int(display.frame.width)) x \(Int(display.frame.height))",
                detail: "\(viewModel.snapshot?.windows.filter { $0.displayIndex == display.index }.count ?? 0) window(s)",
                isPrimary: display.isMain,
                isSelected: viewModel.filterState.selectedDisplayIndex == display.index
            )
        }

        return DSDisplayArrangementCanvas(
            items: items,
            preferredHeight: 250,
            onTap: { tappedID in
                guard let displayIndex = Int(tappedID) else { return }
                viewModel.filterState.selectedDisplayIndex = displayIndex
            }
        )
        .padding(.vertical, 4)
    }

    // MARK: - Display List Section

    @ViewBuilder
    private var displayListSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Displays")
                .font(.headline)

            // All Displays option
            allDisplaysCard

            // Individual displays
            if let snapshot = viewModel.snapshot {
                ForEach(snapshot.displays) { display in
                    displayCard(for: display)
                }
            }
        }
    }

    private var allDisplaysCard: some View {
        let isSelected = viewModel.filterState.selectedDisplayIndex == nil
        let windowCount = viewModel.snapshot?.windows.count ?? 0

        return HStack {
            Image(systemName: "rectangle.on.rectangle")
                .foregroundStyle(isSelected ? .primary : .secondary)
                .frame(width: 32)
                .font(.title2)

            VStack(alignment: .leading, spacing: 4) {
                Text("All Displays")
                    .fontWeight(isSelected ? .semibold : .regular)
                Text("\(windowCount) windows total")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(DesignTokens.Brand.accent)
            }
        }
        .padding()
        .background(isSelected ? DesignTokens.Brand.accent.opacity(0.1) : DesignTokens.Surface.card)
        .cornerRadius(8)
        .contentShape(Rectangle())
        .onTapGesture {
            viewModel.filterState.selectedDisplayIndex = nil
        }
    }

    private func displayCard(for display: DisplayInfo) -> some View {
        let isSelected = viewModel.filterState.selectedDisplayIndex == display.index
        let windowCount = viewModel.snapshot?.windows.filter { $0.displayIndex == display.index }.count ?? 0
        let isExpanded = viewModel.expandedDisplayIDs.contains(display.displayID)

        return VStack(spacing: 0) {
            // Main card row
            HStack {
                Image(systemName: "display")
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .frame(width: 32)
                    .font(.title2)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(display.name ?? "Display \(display.index)")
                            .fontWeight(isSelected || display.isMain ? .semibold : .regular)
                        if display.isMain {
                            Text("MAIN")
                                .font(.caption2)
                                .fontWeight(.medium)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(DesignTokens.Brand.accent.opacity(0.2))
                                .foregroundStyle(DesignTokens.Brand.accent)
                                .cornerRadius(4)
                        }
                    }

                    HStack(spacing: 12) {
                        Text("\(Int(display.frame.width)) \u{00D7} \(Int(display.frame.height))")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Text("@ \(String(format: "%.1f", display.scaleFactor))x")
                            .font(.caption)
                            .foregroundStyle(.tertiary)

                        Text("\(windowCount) windows")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                // Expand button
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        viewModel.toggleDisplayExpanded(display.displayID)
                    }
                } label: {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help(isExpanded ? "Collapse details" : "Show details")

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(DesignTokens.Brand.accent)
                }
            }
            .padding()
            .contentShape(Rectangle())
            .onTapGesture {
                viewModel.filterState.selectedDisplayIndex = display.index
            }

            // Expandable details section
            if isExpanded {
                displayDetailsSection(display: display)
                    .padding(.horizontal)
                    .padding(.bottom)
            }
        }
        .background(isSelected ? DesignTokens.Brand.accent.opacity(0.1) : DesignTokens.Surface.card)
        .cornerRadius(8)
    }

    @ViewBuilder
    private func displayDetailsSection(display: DisplayInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
                .padding(.bottom, 4)

            // Display ID and Index
            HStack(spacing: 16) {
                detailItem(label: "Display ID", value: String(format: "0x%X", display.displayID))
                detailItem(label: "Index", value: "#\(display.index)")
            }

            // Frame info
            HStack(spacing: 16) {
                detailItem(
                    label: "Frame",
                    value: "(\(Int(display.frame.origin.x)), \(Int(display.frame.origin.y))) \(Int(display.frame.width))\u{00D7}\(Int(display.frame.height))"
                )
            }

            // Visible frame info
            HStack(spacing: 16) {
                detailItem(
                    label: "Visible Frame",
                    value: "(\(Int(display.visibleFrame.origin.x)), \(Int(display.visibleFrame.origin.y))) \(Int(display.visibleFrame.width))\u{00D7}\(Int(display.visibleFrame.height))"
                )
            }

            // Insets calculated from frame difference
            let topInset = Int(display.frame.height - display.visibleFrame.height - (display.visibleFrame.origin.y - display.frame.origin.y))
            let bottomInset = Int(display.visibleFrame.origin.y - display.frame.origin.y)
            let leftInset = Int(display.visibleFrame.origin.x - display.frame.origin.x)
            let rightInset = Int(display.frame.width - display.visibleFrame.width - CGFloat(leftInset))

            HStack(spacing: 16) {
                detailItem(
                    label: "Insets (T/B/L/R)",
                    value: "\(topInset) / \(bottomInset) / \(leftInset) / \(rightInset)"
                )
            }
        }
        .font(.caption)
    }

    private func detailItem(label: String, value: String) -> some View {
        HStack(spacing: 4) {
            Text(label + ":")
                .foregroundStyle(.tertiary)
            Text(value)
                .foregroundStyle(.secondary)
                .fontWeight(.medium)
        }
    }
}
