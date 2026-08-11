//
//  DesignSystemSectionView.swift
//  DeskJig
//
//  Created by Codex on 02/03/26.
//

import SwiftUI
import KeyboardShortcuts
import DeskJigShared

#if DEBUG
/// Debug-only design system showcase for settings UI components.
struct DesignSystemSectionView: View {
    @State private var isLoading: Bool = false
    @State private var isToggleOn: Bool = true
    @State private var isToggleOff: Bool = false
    @State private var sliderValue: Double = 5
    @State private var isDisclosureExpanded: Bool = true

    // Form component state
    @State private var basicText: String = ""
    @State private var iconText: String = ""
    @State private var errorText: String = "invalid-email"
    @State private var successText: String = "johndoe"
    @State private var textAreaText: String = ""
    @State private var selectedOption: String? = nil
    @State private var selectedOptionError: String? = nil
    @State private var folderPath: String = ""
    @State private var verifiedFolderPath: String = "/Users/developer/projects"
    @State private var folderVerificationStatus: DSFolderVerificationStatus = .none
    @State private var formFieldText: String = ""
    @State private var formFieldSelection: String? = nil
    @State private var interfaceScale: String = "Regular"
    @AppStorage("appearance.theme") private var appearanceTheme: AppTheme = .dark

    // App Config Card state
    @State private var chromeProfile: String? = "Default"
    @State private var shouldRestoreTabs: Bool = true
    @State private var appConfigPath: String = "/Users/developer/projects/myapp"
    @State private var appConfigVerificationStatus: DSFolderVerificationStatus = .verified

    // Monitor preview state
    @State private var selectedPreviewWindowId: UUID? = nil

    // Keyboard shortcut recorder state
    @State private var recordedShortcut: String? = nil
    private let hotkeyBadgeNameOne = KeyboardShortcuts.Name("designSystem.hotkeyBadge.one")
    private let hotkeyBadgeNameTwo = KeyboardShortcuts.Name("designSystem.hotkeyBadge.two")
    private let hotkeyBadgeNameThree = KeyboardShortcuts.Name("designSystem.hotkeyBadge.three")
    private let hotkeyBadgeNameEmpty = KeyboardShortcuts.Name("designSystem.hotkeyBadge.empty")
    private let workspaceItemShortcutName = KeyboardShortcuts.Name("designSystem.workspaceListItem.shortcut")

    @EnvironmentObject private var confirmationManager: DSConfirmationManager

    private var hotkeyBadgeConflictNames: [KeyboardShortcuts.Name] {
        [
            hotkeyBadgeNameOne,
            hotkeyBadgeNameTwo,
            hotkeyBadgeNameThree,
            hotkeyBadgeNameEmpty
        ]
    }

    // Workspace list item state
    @State private var workspaceItemEditing: Bool = false
    @State private var workspaceItemEditedName: String = "Development"
    @State private var workspaceItemEditedIcon: String = "💻"
    @State private var workspaceItemSelectedWindow: UUID? = nil
    @State private var workspaceItemFavorite: Bool = false
    @State private var workspaceItemShortcut: String? = "⌘1"

    // Selected window config for workspace demo
    @State private var workspaceSelectedPath: String = ""
    @State private var workspacePathStatus: DSFolderVerificationStatus = .none

    // Chrome config for workspace demo
    @State private var workspaceChromeProfile: String? = "Default"
    @State private var workspaceShouldRestoreTabs: Bool = true
    @State private var workspaceChromeTabs: [String] = [
        "https://github.com/anthropics/claude-code",
        "https://stackoverflow.com/questions/swift"
    ]

    // Store window IDs for demo selection (stable across re-renders)
    @State private var demoTerminalWindowId: UUID = UUID()
    @State private var demoChromeWindowId: UUID = UUID()
    @State private var toastPlacement: NotificationPresenter.PresentationEdge = .topTrailing
    @State private var toastTriggerCount: Int = 0
    @State private var toastActionCount: Int = 0
    @State private var voiceToastCancelCount: Int = 0
    @State private var voiceToastNotificationID: UUID? = nil
    @State private var voiceToastCountdownTask: Task<Void, Never>? = nil
    private static let voiceToastCountdownSeconds = 3

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.gapLarge) {
            header

            SettingsSection("Buttons") {
                VStack(alignment: .leading, spacing: 16) {
                    buttonRow(title: "Primary / Secondary / Tertiary") {
                        HStack(spacing: 12) {
                            Button("Primary") {}
                                .buttonStyle(.dsButton(variant: .primary))
                            Button("Secondary") {}
                                .buttonStyle(.dsButton(variant: .secondary))
                            Button("Tertiary") {}
                                .buttonStyle(.dsButton(variant: .tertiary))
                        }
                    }

                    buttonRow(title: "Destructive") {
                        HStack(spacing: 12) {
                            Button("Danger") {}
                                .buttonStyle(.dsButton(variant: .danger))
                        }
                    }

                    buttonRow(title: "Community") {
                        Button {
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "person.3.fill")
                                Text("Join Community")
                            }
                        }
                        .buttonStyle(.dsButton(variant: .green))
                    }

                    buttonRow(title: "With Icons") {
                        HStack(spacing: 12) {
                            Button {
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "plus")
                                    Text("Add")
                                }
                            }
                            .buttonStyle(.dsButton(variant: .primary))

                            Button {
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "arrow.down.to.line")
                                    Text("Download")
                                }
                            }
                            .buttonStyle(.dsButton(variant: .secondary))
                        }
                    }

                    buttonRow(title: "Loading") {
                        Button {
                            simulateLoading()
                        } label: {
                            HStack(spacing: 8) {
                                if isLoading {
                                    ProgressView()
                                        .controlSize(.small)
                                }
                                Text(isLoading ? "Loading..." : "Click to Load")
                            }
                        }
                        .buttonStyle(.dsButton(variant: .primary))
                        .disabled(isLoading)
                    }

                    buttonRow(title: "Icon Buttons") {
                        HStack(spacing: 12) {
                            Button {
                            } label: {
                                Image(systemName: "plus")
                            }
                            .buttonStyle(.dsButton(variant: .secondary, isIconOnly: true))

                            Button {
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.dsButton(variant: .danger, isIconOnly: true))

                            Button {
                            } label: {
                                Image(systemName: "sparkles")
                            }
                            .buttonStyle(.dsButton(variant: .primary, isIconOnly: true))
                        }
                    }

                    buttonRow(title: "Button Pairs (Cancel / Save)") {
                        HStack(spacing: 12) {
                            Button("Cancel") {}
                                .buttonStyle(.dsButton(variant: .secondary))
                            Button("Save") {}
                                .buttonStyle(.dsButton(variant: .primary))
                        }
                    }

                    buttonRow(title: "Button Pairs (with Icons)") {
                        HStack(spacing: 12) {
                            Button {
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "xmark")
                                    Text("Discard")
                                }
                            }
                            .buttonStyle(.dsButton(variant: .danger))

                            Button {
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "checkmark")
                                    Text("Apply")
                                }
                            }
                            .buttonStyle(.dsButton(variant: .success))
                        }
                    }
                }
            }

            SettingsSection("Theme") {
                SettingsRow("Theme") {
                    DSThemePicker(selection: $appearanceTheme)
                }
            }

            SettingsSection("Settings Rows") {
                SettingsRow("Interface Scale") {
                    DSPicker(
                        options: ["Compact", "Regular", "Large"],
                        selection: $interfaceScale,
                        labelText: { $0 }
                    )
                }

                SettingsRow("Open DeskJig") {
                    HotkeyRecorderView(
                        title: "",
                        name: .showWorkspaceView,
                        labelWidth: 0
                    )
                }

                SettingsRowVertical("Auto-Close Delay", subtitle: "Seconds before the menu closes") {
                    SettingsSlider(value: $sliderValue, range: 1...10, step: 0.5, unit: "s")
                }
            }

            SettingsSection("Toggles & Status") {
                SettingsToggle(
                    title: "Auto-Close Menu",
                    subtitle: "Automatically close the menu after a period of inactivity",
                    isOn: $isToggleOn
                )

                SettingsToggle(
                    title: "Hide all apps before restore",
                    subtitle: "Temporarily hide all apps to reduce window overlap during restore",
                    isOn: $isToggleOff
                )

                HStack(spacing: 16) {
                    DSStatusLabel(
                        text: "Connected",
                        systemIcon: "checkmark.circle.fill",
                        color: DesignTokens.Status.success
                    )
                    DSStatusLabel(
                        text: "Warning",
                        systemIcon: "exclamationmark.triangle.fill",
                        color: DesignTokens.Status.warning
                    )
                    DSStatusLabel(
                        text: "Error",
                        systemIcon: "xmark.octagon.fill",
                        color: DesignTokens.Status.error
                    )
                }
            }

            SettingsSection("Disclosure Groups") {
                SettingsDisclosureGroup("Thirds", isExpanded: $isDisclosureExpanded) {
                    SettingsRow("Left third") {
                        HotkeyRecorderView(title: "", name: .moveWindowToLeftThird, labelWidth: 0)
                    }
                    SettingsRow("Center third") {
                        HotkeyRecorderView(title: "", name: .moveWindowToCenterThird, labelWidth: 0)
                    }
                    SettingsRow("Right third") {
                        HotkeyRecorderView(title: "", name: .moveWindowToRightThird, labelWidth: 0)
                    }
                }
            }

            SettingsSection("Form Inputs") {
                VStack(alignment: .leading, spacing: 16) {
                    formInputRow(title: "Basic Text Field") {
                        DSTextField(
                            placeholder: "Enter text...",
                            text: $basicText
                        )
                    }

                    formInputRow(title: "With Leading Icon") {
                        DSTextField(
                            placeholder: "Search...",
                            text: $iconText,
                            leadingIcon: "magnifyingglass"
                        )
                    }

                    formInputRow(title: "Text Area") {
                        DSTextArea(
                            placeholder: "Write a detailed note...",
                            text: $textAreaText,
                            minHeight: 140,
                            maxHeight: 220
                        )
                    }

                    formInputRow(title: "Error State") {
                        DSTextField(
                            placeholder: "Email address",
                            text: $errorText,
                            leadingIcon: "envelope",
                            validationState: .error("Please enter a valid email")
                        )
                    }

                    formInputRow(title: "Success State") {
                        DSTextField(
                            placeholder: "Username",
                            text: $successText,
                            leadingIcon: "person",
                            validationState: .success("Username available")
                        )
                    }

                    formInputRow(title: "Disabled") {
                        DSTextField(
                            placeholder: "Cannot edit",
                            text: .constant("Disabled input"),
                            isDisabled: true
                        )
                    }
                }
            }

            SettingsSection("Dropdowns") {
                VStack(alignment: .leading, spacing: 16) {
                    formInputRow(title: "Basic Dropdown") {
                        DSSelect(
                            options: [
                                DSSelectOption(id: "opt1", label: "Option 1"),
                                DSSelectOption(id: "opt2", label: "Option 2"),
                                DSSelectOption(id: "opt3", label: "Option 3")
                            ],
                            selection: $selectedOption,
                            placeholder: "Select an option..."
                        )
                    }

                    formInputRow(title: "Error State") {
                        DSSelect(
                            options: [
                                DSSelectOption(id: "opt1", label: "Option 1"),
                                DSSelectOption(id: "opt2", label: "Option 2")
                            ],
                            selection: $selectedOptionError,
                            placeholder: "Required selection...",
                            validationState: .error("This field is required")
                        )
                    }
                }
            }

            SettingsSection("Folder Pickers") {
                VStack(alignment: .leading, spacing: 16) {
                    formInputRow(title: "Basic Folder Picker") {
                        DSFolderPicker(
                            path: $folderPath,
                            placeholder: "/path/to/project"
                        )
                    }

                    formInputRow(title: "With Verify Button") {
                        DSFolderPicker(
                            path: $verifiedFolderPath,
                            placeholder: "/path/to/project",
                            verificationStatus: folderVerificationStatus,
                            onVerify: { path in
                                simulateVerification(path: path)
                            }
                        )
                    }
                }
            }

            SettingsSection("Form Field Wrappers") {
                VStack(alignment: .leading, spacing: 20) {
                    DSFormField(label: "Username") {
                        DSTextField(
                            placeholder: "Enter username...",
                            text: $formFieldText
                        )
                    }

                    DSFormField(
                        label: "Country",
                        subtitle: "Select your country of residence"
                    ) {
                        DSSelect(
                            options: [
                                DSSelectOption(id: "us", label: "United States"),
                                DSSelectOption(id: "uk", label: "United Kingdom"),
                                DSSelectOption(id: "ca", label: "Canada")
                            ],
                            selection: $formFieldSelection,
                            placeholder: "Select country..."
                        )
                    }
                }
            }

            SettingsSection("Keyboard Shortcuts") {
                VStack(alignment: .leading, spacing: 16) {
                    formInputRow(title: "Key Badges (Individual)") {
                        HStack(spacing: 8) {
                            DSKeyBadge(key: "⌘", size: .small)
                            DSKeyBadge(key: "⇧", size: .medium)
                            DSKeyBadge(key: "K", size: .large)
                            DSKeyBadge(key: "Space")
                            DSKeyBadge(key: "Enter")
                        }
                    }

                    formInputRow(title: "Keyboard Shortcut Display") {
                        VStack(alignment: .leading, spacing: 8) {
                            DSKeyboardShortcut(keys: ["⌘", "K"])
                            DSKeyboardShortcut(keys: ["⌘", "⇧", "P"])
                            DSKeyboardShortcut(shortcut: "⌥⌃Space", size: .small)
                        }
                    }

                    formInputRow(title: "Shortcut Recorder (DS)") {
                        DSKeyboardShortcutRecorder(
                            shortcut: $recordedShortcut,
                            placeholder: "Click to record"
                        )
                    }

                    Text("System Hotkey Recorder (KeyboardShortcuts):")
                        .font(brand: .body3)
                        .foregroundStyle(DesignTokens.Text.secondary)

                    SettingsRow("Record Shortcut") {
                        HotkeyRecorderView(
                            title: "",
                            name: .showWorkspaceView,
                            labelWidth: 0
                        )
                    }
                }
            }

            SettingsSection("Card Headers") {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Reusable header component with icon, title, and optional subtitle:")
                        .font(brand: .body3)
                        .foregroundStyle(DesignTokens.Text.secondary)

                    VStack(alignment: .leading, spacing: 12) {
                        DSCardHeader(
                            icon: "globe",
                            title: "Google Chrome",
                            subtitle: "Chrome Profile"
                        )
                        DSCardHeader(
                            icon: "chevron.left.forwardslash.chevron.right",
                            title: "VS Code",
                            subtitle: "Open by Path"
                        )
                        DSCardHeader(
                            icon: "message",
                            title: "Slack"
                        )
                    }
                    .padding(DesignTokens.Card.padding)
                    .dsCard()
                }
            }

            SettingsSection("App Config Cards") {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Composed cards for app configuration panels:")
                        .font(brand: .body3)
                        .foregroundStyle(DesignTokens.Text.secondary)

                    // Chrome Profile Mode
                    DSAppConfigCard(
                        appName: "Google Chrome",
                        bundleId: "com.google.Chrome",
                        icon: "globe",
                        chromeProfile: $chromeProfile,
                        shouldRestoreTabs: $shouldRestoreTabs,
                        chromeProfiles: [
                            DSSelectOption(id: "Default", label: "Default"),
                            DSSelectOption(id: "Work", label: "Work"),
                            DSSelectOption(id: "Personal", label: "Personal")
                        ],
                        tabs: [
                            "GitHub - Pull Requests",
                            "Stack Overflow - Swift Question",
                            "Apple Developer Documentation"
                        ]
                    )

                    // Open-by-Path Mode
                    DSAppConfigCard(
                        appName: "VS Code",
                        bundleId: "com.microsoft.VSCode",
                        icon: "chevron.left.forwardslash.chevron.right",
                        path: $appConfigPath,
                        pathVerificationStatus: appConfigVerificationStatus,
                        onVerifyPath: { path in
                            appConfigVerificationStatus = .verifying
                            Task {
                                await Task.sleepUnlessCancelled(nanoseconds: 1_000_000_000)
                                let fileManager = FileManager.default
                                var isDirectory: ObjCBool = false
                                if fileManager.fileExists(atPath: path, isDirectory: &isDirectory),
                                   isDirectory.boolValue {
                                    appConfigVerificationStatus = .verified
                                } else {
                                    appConfigVerificationStatus = .failed("Directory does not exist")
                                }
                            }
                        }
                    )

                    // Standard Mode
                    DSAppConfigCard(
                        appName: "Slack",
                        bundleId: "com.tinyspeck.slackmacgap",
                        icon: "message"
                    )
                }
            }

            SettingsSection("Pulsating Effects") {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Animated indicators for special apps (Chrome, IDEs, terminals):")
                        .font(brand: .body3)
                        .foregroundStyle(DesignTokens.Text.secondary)

                    formInputRow(title: "Pulsating Borders") {
                        HStack(spacing: 16) {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(DesignTokens.Surface.card)
                                .frame(width: 60, height: 40)
                                .dsPulsatingBorder(color: DesignTokens.SpecialApp.chrome, cornerRadius: 8)

                            RoundedRectangle(cornerRadius: 8)
                                .fill(DesignTokens.Surface.card)
                                .frame(width: 60, height: 40)
                                .dsPulsatingBorder(color: DesignTokens.SpecialApp.ide, cornerRadius: 8)

                            RoundedRectangle(cornerRadius: 8)
                                .fill(DesignTokens.Surface.card)
                                .frame(width: 60, height: 40)
                                .dsPulsatingBorder(color: DesignTokens.SpecialApp.chrome, isSelected: true, cornerRadius: 8)

                            Text("(selected)")
                                .font(brand: .body4)
                                .foregroundStyle(DesignTokens.Text.muted)
                        }
                    }

                    formInputRow(title: "Indicator Dots") {
                        HStack(spacing: 16) {
                            DSPulsatingIndicator(color: DesignTokens.SpecialApp.chrome, isActive: true)
                            DSPulsatingIndicator(color: DesignTokens.SpecialApp.ide, isActive: true)
                            DSPulsatingIndicator(color: DesignTokens.Status.success, isActive: true)
                            DSPulsatingIndicator(color: DesignTokens.Status.warning, isActive: true)
                        }
                    }

                    formInputRow(title: "Special App Indicators (Badge + Border)") {
                        HStack(spacing: 24) {
                            VStack(spacing: 4) {
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(DesignTokens.Surface.elevated)
                                    .frame(width: 48, height: 32)
                                    .dsSpecialAppIndicator(appType: .chrome, isActive: true)
                                Text("Chrome")
                                    .font(brand: .body4)
                                    .foregroundStyle(DesignTokens.Text.muted)
                            }

                            VStack(spacing: 4) {
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(DesignTokens.Surface.elevated)
                                    .frame(width: 48, height: 32)
                                    .dsSpecialAppIndicator(appType: .ide, isActive: true)
                                Text("IDE")
                                    .font(brand: .body4)
                                    .foregroundStyle(DesignTokens.Text.muted)
                            }

                            VStack(spacing: 4) {
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(DesignTokens.Surface.elevated)
                                    .frame(width: 48, height: 32)
                                    .dsSpecialAppIndicator(appType: .chrome, isActive: true, isSelected: true)
                                Text("Selected")
                                    .font(brand: .body4)
                                    .foregroundStyle(DesignTokens.Text.muted)
                            }
                        }
                    }
                }
            }

            SettingsSection("Monitor Previews") {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Workspace layout previews showing windows on monitors:")
                        .font(brand: .body3)
                        .foregroundStyle(DesignTokens.Text.secondary)

                    formInputRow(title: "Single Monitor") {
                        DSMonitorPreview(
                            title: "Display",
                            windows: [
                                DSPreviewWindow(
                                    appName: "Finder",
                                    icon: appIcon(for: "com.apple.finder"),
                                    xPercent: 0.05,
                                    yPercent: 0.05,
                                    widthPercent: 0.4,
                                    heightPercent: 0.5
                                ),
                                DSPreviewWindow(
                                    appName: "Notes",
                                    icon: appIcon(for: "com.apple.Notes"),
                                    xPercent: 0.5,
                                    yPercent: 0.3,
                                    widthPercent: 0.45,
                                    heightPercent: 0.65
                                )
                            ],
                            isPrimary: true
                        )
                    }

                    formInputRow(title: "Multi-Monitor Setup") {
                        DSScreenPreviewContainer(
                            screens: [
                                DSPreviewScreen(
                                    id: 0,
                                    title: "Monitor 1",
                                    isPrimary: true,
                                    windows: monitorPreviewWindows1
                                ),
                                DSPreviewScreen(
                                    id: 1,
                                    title: "Monitor 2",
                                    isPrimary: false,
                                    windows: monitorPreviewWindows2
                                )
                            ],
                            isInEditMode: true,
                            selectedWindowId: selectedPreviewWindowId,
                            onWindowTapped: { window in
                                selectedPreviewWindowId = window.id
                            }
                        )
                    }

                    Text("Click a window to select it. Pulsating indicates special app configuration.")
                        .font(brand: .body4)
                        .foregroundStyle(DesignTokens.Text.muted)
                }
            }

            SettingsSection("Toggle Buttons") {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Icon toggle buttons for favorites, pins, and other state toggles:")
                        .font(brand: .body3)
                        .foregroundStyle(DesignTokens.Text.secondary)

                    formInputRow(title: "Favorite Toggle") {
                        HStack(spacing: 16) {
                            Button { } label: {
                                Image(systemName: "star.fill")
                            }
                            .buttonStyle(.dsFavorite(isSelected: true))

                            Button { } label: {
                                Image(systemName: "star")
                            }
                            .buttonStyle(.dsFavorite(isSelected: false))

                            Text("(selected / unselected)")
                                .font(brand: .body4)
                                .foregroundStyle(DesignTokens.Text.muted)
                        }
                    }

                    formInputRow(title: "Generic Toggle") {
                        HStack(spacing: 16) {
                            Button { } label: {
                                Image(systemName: "pin.fill")
                            }
                            .buttonStyle(.dsToggle(isSelected: true))

                            Button { } label: {
                                Image(systemName: "pin")
                            }
                            .buttonStyle(.dsToggle(isSelected: false))
                        }
                    }
                }
            }

            SettingsSection("Hotkey Badges") {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Compact hotkey displays for card footers:")
                        .font(brand: .body3)
                        .foregroundStyle(DesignTokens.Text.secondary)

                    formInputRow(title: "With Shortcut") {
                        HStack(spacing: 16) {
                            DSHotkeyBadge(shortcut: "⌘1", shortcutName: hotkeyBadgeNameOne) {
                                DSHotkeyRecorderPopover(
                                    name: hotkeyBadgeNameOne,
                                    conflictNames: hotkeyBadgeConflictNames
                                )
                            }
                            DSHotkeyBadge(shortcut: "⌘⇧W", shortcutName: hotkeyBadgeNameTwo) {
                                DSHotkeyRecorderPopover(
                                    name: hotkeyBadgeNameTwo,
                                    conflictNames: hotkeyBadgeConflictNames
                                )
                            }
                            DSHotkeyBadge(shortcut: "⌥⌃Space", shortcutName: hotkeyBadgeNameThree) {
                                DSHotkeyRecorderPopover(
                                    name: hotkeyBadgeNameThree,
                                    conflictNames: hotkeyBadgeConflictNames
                                )
                            }
                        }
                    }

                    formInputRow(title: "Record Placeholder") {
                        DSHotkeyBadge(shortcut: nil, onTap: { print("Record tapped") }, shortcutName: hotkeyBadgeNameEmpty) {
                            DSHotkeyRecorderPopover(
                                name: hotkeyBadgeNameEmpty,
                                conflictNames: hotkeyBadgeConflictNames
                            )
                        }
                    }
                }
            }

            SettingsSection("Emoji Picker") {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Emoji grid for workspace icons:")
                        .font(brand: .body3)
                        .foregroundStyle(DesignTokens.Text.secondary)

                    DSEmojiPicker(
                        selectedEmoji: $workspaceItemEditedIcon,
                        isPresented: .constant(true)
                    )
                }
            }

            SettingsSection("Workspace List Items") {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Interactive workspace card with edit mode. Click the hotkey badge to open the shortcut recorder popover. Hover to see help icon:")
                        .font(brand: .body3)
                        .foregroundStyle(DesignTokens.Text.secondary)

                    // Single fully-functional workspace list item with Chrome config support
                    DSWorkspaceListItem(
                        name: "Development",
                        icon: "💻",
                        isFavorite: workspaceItemFavorite,
                        screens: workspaceScreens,
                        shortcut: workspaceItemShortcut,
                        shortcutRecorderName: workspaceItemShortcutName,
                        shortcutConflictNames: [workspaceItemShortcutName],
                        isEditing: $workspaceItemEditing,
                        editedName: $workspaceItemEditedName,
                        editedIcon: $workspaceItemEditedIcon,
                        selectedWindowId: $workspaceItemSelectedWindow,
                        selectedWindowPath: $workspaceSelectedPath,
                        selectedWindowPathStatus: workspacePathStatus,
                        onVerifySelectedPath: { path in
                            workspacePathStatus = .verifying
                            Task {
                                await Task.sleepUnlessCancelled(nanoseconds: 800_000_000)
                                let fileManager = FileManager.default
                                var isDirectory: ObjCBool = false
                                if fileManager.fileExists(atPath: path, isDirectory: &isDirectory),
                                   isDirectory.boolValue {
                                    workspacePathStatus = .verified
                                } else {
                                    workspacePathStatus = .failed("Directory does not exist")
                                }
                            }
                        },
                        onClearSelectedPath: {
                            workspaceSelectedPath = ""
                            workspacePathStatus = .none
                        },
                        selectedChromeProfile: $workspaceChromeProfile,
                        selectedShouldRestoreTabs: $workspaceShouldRestoreTabs,
                        selectedChromeTabs: $workspaceChromeTabs,
                        chromeProfiles: [
                            DSSelectOption(id: "Default", label: "Default"),
                            DSSelectOption(id: "Work", label: "Work"),
                            DSSelectOption(id: "Personal", label: "Personal")
                        ],
                        onLoadChromeTabs: {
                            // Simulate loading tabs from Chrome with 2-second delay
                            await Task.sleepUnlessCancelled(nanoseconds: 2_000_000_000)

                            // Simulate occasional failure (20% chance)
                            if Int.random(in: 1...5) == 1 {
                                return false
                            }

                            workspaceChromeTabs = [
                                "https://github.com",
                                "https://stackoverflow.com",
                                "https://developer.apple.com"
                            ]
                            return true
                        },
                        onAddChromeTab: { url in
                            workspaceChromeTabs.append(url)
                        },
                        onRemoveChromeTab: { index in
                            if workspaceChromeTabs.indices.contains(index) {
                                workspaceChromeTabs.remove(at: index)
                            }
                        },
                        onEditTapped: { workspaceItemEditing = true },
                        onFavoriteTapped: { workspaceItemFavorite.toggle() },
                        onSave: {
                            workspaceItemEditing = false
                            workspaceItemSelectedWindow = nil
                        },
                        onCancel: {
                            workspaceItemEditing = false
                            workspaceItemSelectedWindow = nil
                            workspaceSelectedPath = ""
                            workspacePathStatus = .none
                        },
                        onRecordShortcut: {
                            // In real app, this would open shortcut recorder
                            // For demo, just set a sample shortcut
                            if workspaceItemShortcut == nil {
                                workspaceItemShortcut = "⌘⇧D"
                            }
                        },
                        onClearShortcut: {
                            workspaceItemShortcut = nil
                        },
                        onWindowTapped: { window in
                            // Only select windows with special app types
                            if window.specialAppType != nil {
                                workspaceItemSelectedWindow = window.id
                                workspaceSelectedPath = ""
                                workspacePathStatus = .none
                            }
                        }
                    )
                }
            }

            SettingsSection("Toasts") {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Design-system toast component with icon, message, subtext, optional action, and close.")
                        .font(brand: .body3)
                        .foregroundStyle(DesignTokens.Text.secondary)

                    formInputRow(title: "Static Preview") {
                        VStack(alignment: .leading, spacing: 12) {
                            DSToast(
                                icon: "checkmark.circle.fill",
                                message: "Workspace saved",
                                subtext: "All windows and monitor assignments were captured.",
                                iconColor: DesignTokens.Brand.accent,
                                onClose: {}
                            )

                            DSToast(
                                icon: "arrow.uturn.backward.circle.fill",
                                message: "Workspace deleted",
                                subtext: "Restore this workspace before it is permanently removed.",
                                iconColor: DesignTokens.Status.error,
                                actionTitle: "Undo",
                                action: {},
                                onClose: {}
                            )

                            DSToast(
                                icon: "waveform.circle.fill",
                                message: "Launch app",
                                subtext: "App: Xcode\nDisplay: index 1\nPosition: bottom-left-quarter\nExecuting in 3s",
                                iconColor: .blue,
                                actionTitle: "Cancel",
                                action: {},
                                onClose: {}
                            )
                        }
                    }

                    formInputRow(title: "System Placement") {
                        Picker("Toast Placement", selection: $toastPlacement) {
                            Text("Top Right")
                                .tag(NotificationPresenter.PresentationEdge.topTrailing)
                            Text("Bottom Right")
                                .tag(NotificationPresenter.PresentationEdge.bottomTrailing)
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 360)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 12) {
                            Button("Trigger System Toast") {
                                triggerSystemToast()
                            }
                            .buttonStyle(.dsButton(variant: .primary))

                            Button("Trigger Voice-Style Toast") {
                                triggerVoiceStyleToast()
                            }
                            .buttonStyle(.dsButton(variant: .secondary))
                        }

                        Text("Action taps: \(toastActionCount) • Voice cancels: \(voiceToastCancelCount)")
                            .font(brand: .body4)
                            .foregroundStyle(DesignTokens.Text.tertiary)
                    }
                }
            }

            SettingsSection("Modals") {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Confirmation modal overlay with destructive action.")
                        .font(brand: .body3)
                        .foregroundStyle(DesignTokens.Text.secondary)

                    Button("Show Confirmation") {
                        confirmationManager.present(
                            title: "Delete Workspace?",
                            message: "This will permanently remove the workspace and its saved layout.",
                            confirmTitle: "Delete Workspace",
                            cancelTitle: "Cancel",
                            isDestructive: true,
                            onConfirm: {},
                            onCancel: {}
                        )
                    }
                    .buttonStyle(.dsButton(variant: .secondary, size: .medium))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onDisappear {
            cancelVoiceStyleToast(countAsCancel: false)
        }
    }

    // MARK: - App Icon Helper

    /// Loads an app icon from the system using the app's bundle identifier
    private func appIcon(for bundleId: String) -> NSImage? {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
            return nil
        }
        return NSWorkspace.shared.icon(forFile: appURL.path)
    }

    // Sample windows for monitor preview demos
    private var monitorPreviewWindows1: [DSPreviewWindow] {
        [
            DSPreviewWindow(
                appName: "Chrome",
                icon: appIcon(for: "com.google.Chrome"),
                xPercent: 0.0,
                yPercent: 0.0,
                widthPercent: 0.5,
                heightPercent: 1.0,
                specialAppType: .chrome
            ),
            DSPreviewWindow(
                appName: "VS Code",
                icon: appIcon(for: "com.microsoft.VSCode") ?? appIcon(for: "todesktop.com.Cursor"),
                xPercent: 0.5,
                yPercent: 0.0,
                widthPercent: 0.5,
                heightPercent: 1.0,
                specialAppType: .ide
            )
        ]
    }

    private var monitorPreviewWindows2: [DSPreviewWindow] {
        [
            DSPreviewWindow(
                appName: "Slack",
                icon: appIcon(for: "com.tinyspeck.slackmacgap"),
                xPercent: 0.0,
                yPercent: 0.0,
                widthPercent: 1.0,
                heightPercent: 0.6
            ),
            DSPreviewWindow(
                appName: "Terminal",
                icon: appIcon(for: "com.apple.Terminal"),
                xPercent: 0.0,
                yPercent: 0.6,
                widthPercent: 1.0,
                heightPercent: 0.4,
                specialAppType: .terminal
            )
        ]
    }

    /// Screens for the workspace demo with stable window IDs (two monitors)
    private var workspaceScreens: [DSPreviewScreen] {
        [
            DSPreviewScreen(
                id: 0,
                title: "Monitor 1",
                isPrimary: true,
                windows: [
                    DSPreviewWindow(
                        id: demoChromeWindowId,
                        appName: "Chrome",
                        icon: appIcon(for: "com.google.Chrome"),
                        xPercent: 0.0,
                        yPercent: 0.0,
                        widthPercent: 0.5,
                        heightPercent: 1.0,
                        specialAppType: .chrome
                    ),
                    DSPreviewWindow(
                        appName: "Notes",
                        icon: appIcon(for: "com.apple.Notes"),
                        xPercent: 0.5,
                        yPercent: 0.0,
                        widthPercent: 0.5,
                        heightPercent: 1.0
                    )
                ]
            ),
            DSPreviewScreen(
                id: 1,
                title: "Monitor 2",
                isPrimary: false,
                windows: [
                    DSPreviewWindow(
                        id: demoTerminalWindowId,
                        appName: "Ghostty",
                        icon: appIcon(for: "com.mitchellh.ghostty") ?? appIcon(for: "com.apple.Terminal"),
                        xPercent: 0.0,
                        yPercent: 0.0,
                        widthPercent: 1.0,
                        heightPercent: 0.6,
                        specialAppType: .terminal
                    ),
                    DSPreviewWindow(
                        appName: "Slack",
                        icon: appIcon(for: "com.tinyspeck.slackmacgap"),
                        xPercent: 0.0,
                        yPercent: 0.6,
                        widthPercent: 1.0,
                        heightPercent: 0.4
                    )
                ]
            )
        ]
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Design System")
                .font(brand: .h2)
                .foregroundStyle(DesignTokens.Text.primary)

            Text("Debug-only catalog of tokens and reusable components used in Settings.")
                .font(brand: .body2)
                .foregroundStyle(DesignTokens.Text.secondary)
        }
    }

    @ViewBuilder
    private func buttonRow<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(brand: .body3)
                .foregroundStyle(DesignTokens.Text.secondary)
            content()
        }
    }

    private func simulateLoading() {
        guard !isLoading else { return }
        isLoading = true
        Task {
            await Task.sleepUnlessCancelled(nanoseconds: 1_500_000_000)
            isLoading = false
        }
    }

    @ViewBuilder
    private func formInputRow<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(brand: .body3)
                .foregroundStyle(DesignTokens.Text.secondary)
            content()
        }
    }

    private func simulateVerification(path: String) {
        folderVerificationStatus = .verifying
        Task {
            await Task.sleepUnlessCancelled(nanoseconds: 1_000_000_000)
            let fileManager = FileManager.default
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
                folderVerificationStatus = .verified
            } else {
                folderVerificationStatus = .failed("Directory does not exist")
            }
        }
    }

    @MainActor
    private func triggerSystemToast() {
        toastTriggerCount += 1
        let triggerIndex = toastTriggerCount

        NotificationPresenter.present(
            .init(
                "Design System Toast \(triggerIndex)",
                text: "This is a live system toast from the design system section.",
                icon: "checkmark.circle.fill",
                iconColor: .green,
                actionTitle: "Undo"
            ),
            tapAction: {
                Task { @MainActor in
                    toastActionCount += 1
                    NotificationPresenter.present(
                        .init(
                            "Undo requested",
                            text: "Toast action callback executed.",
                            icon: "arrow.uturn.backward.circle.fill",
                            iconColor: .yellow
                        ),
                        edge: toastPlacement,
                        for: .seconds(3)
                    )
                }
            },
            edge: toastPlacement,
            for: .seconds(6)
        )
    }

    @MainActor
    private func triggerVoiceStyleToast() {
        cancelVoiceStyleToast(countAsCancel: false)

        let toastID = UUID()
        voiceToastNotificationID = toastID
        let countdownSeconds = Self.voiceToastCountdownSeconds

        func cancelFromUser() {
            cancelVoiceStyleToast(countAsCancel: true)
        }

        NotificationPresenter.present(
            .init(
                "Launch app",
                text: voiceStyleToastText(remainingSeconds: countdownSeconds),
                icon: "waveform.circle.fill",
                iconColor: .blue,
                actionTitle: "Cancel"
            ),
            withID: toastID,
            tapAction: {
                Task { @MainActor in
                    cancelFromUser()
                }
            },
            edge: toastPlacement,
            for: .persistent,
            onDismiss: { reason in
                Task { @MainActor in
                    switch reason {
                    case .action, .close, .swipe:
                        cancelFromUser()
                    case .timeout, .programmatic:
                        break
                    }
                }
            }
        )

        voiceToastCountdownTask = Task { @MainActor in
            for remaining in stride(from: countdownSeconds, through: 1, by: -1) {
                guard !Task.isCancelled, voiceToastNotificationID == toastID else { return }

                NotificationPresenter.update(
                    notificationWithID: toastID,
                    to: .init(
                        "Launch app",
                        text: voiceStyleToastText(remainingSeconds: remaining),
                        icon: "waveform.circle.fill",
                        iconColor: .blue,
                        actionTitle: "Cancel"
                    ),
                    tapAction: {
                        Task { @MainActor in
                            cancelFromUser()
                        }
                    },
                    edge: toastPlacement,
                    for: .persistent
                )

                guard await Task.sleepUnlessCancelled(for: .seconds(1)) else { break }
            }

            guard !Task.isCancelled, voiceToastNotificationID == toastID else { return }
            voiceToastCountdownTask = nil
            voiceToastNotificationID = nil
            NotificationPresenter.dismiss(notificationWithID: toastID)
            NotificationPresenter.present(
                .init(
                    "Voice preview completed",
                    text: "Countdown finished with no cancellation.",
                    icon: "checkmark.circle.fill",
                    iconColor: .green
                ),
                edge: toastPlacement,
                for: .seconds(4)
            )
        }
    }

    @MainActor
    private func cancelVoiceStyleToast(countAsCancel: Bool) {
        if countAsCancel {
            voiceToastCancelCount += 1
        }
        voiceToastCountdownTask?.cancel()
        voiceToastCountdownTask = nil

        if let toastID = voiceToastNotificationID {
            NotificationPresenter.dismiss(notificationWithID: toastID)
            voiceToastNotificationID = nil
        }
    }

    private func voiceStyleToastText(remainingSeconds: Int) -> String {
        [
            "Action: launch_app",
            "App: Xcode",
            "Display: index 1",
            "Position: bottom-left-quarter",
            "Executing in \(remainingSeconds)s"
        ].joined(separator: "\n")
    }
}

#Preview {
    DesignSystemSectionView()
        .padding(32)
        .background(Color.black.opacity(0.9))
        .environmentObject(DSConfirmationManager())
}
#endif
