//  ChromeAppleScriptTests.swift
//  DeskJigSharedTests

import Foundation
import Testing
@testable import DeskJigShared

struct ChromeAppleScriptTests {

    @Test("Extension page script preserves the existing command")
    func opensExtensionsPage() {
        #expect(ChromeAppleScript.openExtensionsPage == expectedChromeScript("""
        tell application "__CHROME__"
            activate
            open location "chrome://extensions"
        end tell
        """))
    }

    @Test("Ordinal window tab script replaces the first tab and appends the rest")
    func replacesActiveTabAndAppendsRemainingTabs() {
        let script = ChromeAppleScript.replaceActiveTabAndAppend(
            ["https://example.com/a\\b", "https://example.com/\"quoted\""],
            inWindowIndex: 3
        )

        #expect(script == expectedChromeScript("""
        tell application "__CHROME__"
            set targetWindow to window 3
            tell targetWindow
                set URL of active tab to "https://example.com/a\\\\b"
            end tell
            tell targetWindow
                make new tab with properties {URL:"https://example.com/\\\"quoted\\\""}
            end tell
        end tell
        """))
    }

    @Test("Front-window script handles empty and populated URL lists")
    func opensFrontWindow() {
        #expect(ChromeAppleScript.openNewFrontWindow(urls: []) == expectedChromeScript("""
        tell application "__CHROME__"
            activate
            make new window
        end tell
        """))

        #expect(ChromeAppleScript.openNewFrontWindow(urls: ["https://one.test", "https://two.test"]) == expectedChromeScript("""
        tell application "__CHROME__"
            activate
            make new window
            tell front window
                set URL of active tab to "https://one.test"
            end tell
            tell front window
                make new tab with properties {URL:"https://two.test"}
            end tell
        end tell
        """))
    }

    @Test("Single-window capture pins ID and delimiter protocol")
    func capturesTabDataByWindowID() {
        #expect(ChromeAppleScript.tabData(inWindowID: 42) == expectedChromeScript("""
        tell application "__CHROME__"
          if it is running is false then
            return ""
          end if

          try
            set chromeWindow to window id 42
            set tabURLs to {}
            repeat with t from 1 to count of tabs of chromeWindow
              set end of tabURLs to (URL of tab t of chromeWindow) as string
            end repeat
            set activeIndex to active tab index of chromeWindow

            set windowBounds to bounds of chromeWindow
            set winLeft to item 1 of windowBounds
            set winTop to item 2 of windowBounds
            set winRight to item 3 of windowBounds
            set winBottom to item 4 of windowBounds
            set boundsString to (winLeft as text) & "," & (winTop as text) & "," & ((winRight - winLeft) as text) & "," & ((winBottom - winTop) as text)

            set oldDelim to AppleScript's text item delimiters
            set AppleScript's text item delimiters to "^^^"
            set tabString to tabURLs as text
            set AppleScript's text item delimiters to oldDelim

            return (activeIndex as text) & "\\t" & boundsString & "\\t" & tabString
          on error errMsg
            return "Error: " & errMsg
          end try
        end tell
        """))
    }

    @Test("Window-ID mutation scripts preserve parameters and escaping")
    func buildsWindowIDMutations() {
        #expect(ChromeAppleScript.appendTabs(
            ["https://one.test/a\\b", "https://two.test/\"q\""],
            toWindowID: 17
        ) == expectedChromeScript("""
        tell application "__CHROME__"
          if it is running is false then return

          try
            set chromeWindow to window id 17
            set urlsToOpen to {"https://one.test/a\\\\b", "https://two.test/\\\"q\\\""}
            repeat with candidate in urlsToOpen
              set candidateURL to candidate as string
              make new tab at end of tabs of chromeWindow with properties {URL:candidateURL}
            end repeat
          on error errMsg
            return "Error: " & errMsg
          end try
        end tell
        """))

        #expect(ChromeAppleScript.setActiveTab(index: 4, inWindowID: 17) == expectedChromeScript("""
        tell application "__CHROME__"
          if it is running is false then return

          try
            set chromeWindow to window id 17
            set active tab index of chromeWindow to 4
          on error errMsg
            return "Error: " & errMsg
          end try
        end tell
        """))

        #expect(ChromeAppleScript.setActiveTabURL("https://example.test/a\\b\"c", inWindowID: 17) == expectedChromeScript("""
        tell application "__CHROME__"
          if it is running is false then return

          try
            set chromeWindow to window id 17
            tell chromeWindow
              set URL of active tab to "https://example.test/a\\\\b\\\"c"
              set index to 1
            end tell
            activate
          on error errMsg
            return "Error: " & errMsg
          end try
        end tell
        """))

        #expect(ChromeAppleScript.closeWindow(windowID: 17) == expectedChromeScript("""
        tell application "__CHROME__"
          if it is running is false then return

          try
            set chromeWindow to window id 17
            close chromeWindow
          on error errMsg
            return "Error: " & errMsg
          end try
        end tell
        """))
    }

    @Test("Bounds script rounds edges like the previous call site")
    func setsRoundedBounds() {
        let bounds = CGRect(x: 10.4, y: 20.6, width: 300.2, height: 400.8)

        #expect(ChromeAppleScript.setBounds(ofWindowID: 8, to: bounds) == expectedChromeScript("""
        tell application "__CHROME__"
          if it is running is false then return

          try
            set chromeWindow to window id 8
            set bounds of chromeWindow to {10, 21, 311, 421}
          on error errMsg
            return "Error: " & errMsg
          end try
        end tell
        """))
    }

    @Test("New-window script covers URLs, optional bounds, activation, and returned ID")
    func opensURLsInPositionedWindow() {
        let script = ChromeAppleScript.openURLsInNewWindow(
            ["https://one.test", "https://two.test/\"quoted\""],
            bounds: CGRect(x: 4.6, y: 7.4, width: 100.5, height: 200.5),
            activate: true
        )

        #expect(script == expectedChromeScript("""
        tell application "__CHROME__"
          set newWin to make new window
          set URL of active tab of newWin to "https://one.test"
          make new tab at end of tabs of newWin with properties {URL: "https://two.test/\\\"quoted\\\""}
          set bounds of newWin to {5, 7, 105, 208}
          set index of newWin to 1
          activate
          return id of newWin
        end tell
        """))

        let inactiveScript = ChromeAppleScript.openURLsInNewWindow(
            ["https://one.test"],
            activate: false
        )
        #expect(inactiveScript == expectedChromeScript("""
        tell application "__CHROME__"
          set newWin to make new window
          set URL of active tab of newWin to "https://one.test"
          return id of newWin
        end tell
        """))
    }

    @Test("Batch close preserves caller-provided descending tab order")
    func closesTabsByWindowID() {
        #expect(ChromeAppleScript.closeTabs(at: [5, 3, 1], inWindowID: 99) == expectedChromeScript("""
        tell application "__CHROME__"
          if it is running is false then return

          try
            set chromeWindow to window id 99
            repeat with idxRef in {5, 3, 1}
              set idx to idxRef as integer
              if (count of tabs of chromeWindow) >= idx then
                close tab idx of chromeWindow
              end if
            end repeat
          on error errMsg
            return "Error: " & errMsg
          end try
        end tell
        """))
    }

    @Test("Bounds-matched scripts share exact System Events window selection")
    func buildsBoundsMatchedOperations() {
        let bounds = CGRect(x: 10.9, y: 20.8, width: 300.7, height: 400.6)

        #expect(ChromeAppleScript.appendTabs(["https://example.test"], matchingBounds: bounds) ==
            expectedBoundsMatchedScript(action: """
            set chromeWindow to window (targetWindow as integer)
            set urlsToOpen to {"https://example.test"}
            repeat with candidate in urlsToOpen
              set candidateURL to candidate as string
              make new tab at end of tabs of chromeWindow with properties {URL:candidateURL}
            end repeat
            """))

        #expect(ChromeAppleScript.setActiveTab(index: 3, matchingBounds: bounds) ==
            expectedBoundsMatchedScript(action: """
            set chromeWindow to window (targetWindow as integer)
            set active tab index of chromeWindow to 3
            """))

        #expect(ChromeAppleScript.closeTab(at: 4, matchingBounds: bounds) ==
            expectedBoundsMatchedScript(action: """
            set chromeWindow to window (targetWindow as integer)
            if (count of tabs of chromeWindow) >= 4 then
              close tab 4 of chromeWindow
            end if
            """))
    }

    @Test("Supplementation and snapshot enumerators preserve their output protocols")
    func buildsWindowEnumerationProtocols() {
        #expect(ChromeAppleScript.windowTabDataWithBoundsAndProfiles == expectedChromeScript("""
        tell application "__CHROME__"
            set results to {}
            set oldDelim to AppleScript's text item delimiters

            repeat with w from 1 to count of windows
                set win to window w
                set winTitle to title of win
                set profileName to "Default"

                -- Extract profile name from Chrome title format: "PageTitle - Google Chrome - ProfileName"
                if winTitle contains " - Google Chrome - " then
                    set AppleScript's text item delimiters to " - Google Chrome - "
                    set parts to text items of winTitle
                    if (count of parts) > 1 then
                        set profileName to last item of parts
                    end if
                else if winTitle contains " - Google Chrome" then
                    set profileName to "Default"
                end if

                -- Get window bounds: {left, top, right, bottom}
                set winBounds to bounds of win
                set winLeft to item 1 of winBounds
                set winTop to item 2 of winBounds
                set winRight to item 3 of winBounds
                set winBottom to item 4 of winBounds
                set winWidth to winRight - winLeft
                set winHeight to winBottom - winTop

                -- Get tab URLs
                set tabList to {}
                repeat with t from 1 to count of tabs of win
                    set theTab to tab t of win
                    set end of tabList to (URL of theTab)
                end repeat

                -- Join tabs with ^^^
                set AppleScript's text item delimiters to "^^^"
                set tabString to tabList as text

                -- Format: "x,y,width,height:::profileName:::url1^^^url2"
                set boundsStr to (winLeft as text) & "," & (winTop as text) & "," & (winWidth as text) & "," & (winHeight as text)
                set end of results to boundsStr & ":::" & profileName & ":::" & tabString
            end repeat

            -- Join results with ###
            set AppleScript's text item delimiters to "###"
            set resultString to results as text
            set AppleScript's text item delimiters to oldDelim

            return resultString
        end tell
        """))

        #expect(ChromeAppleScript.windowSnapshotData == expectedChromeScript("""
        tell application "__CHROME__"
            set results to {}
            set oldDelim to AppleScript's text item delimiters

            repeat with w from 1 to count of windows
                set win to window w
                set winTitle to title of win
                set profileName to "Default"

                -- Extract profile name from Chrome title format: "PageTitle - Google Chrome - ProfileName"
                -- Use " - Google Chrome - " delimiter for reliable extraction
                if winTitle contains " - Google Chrome - " then
                    set AppleScript's text item delimiters to " - Google Chrome - "
                    set parts to text items of winTitle
                    if (count of parts) > 1 then
                        set profileName to last item of parts
                    end if
                else if winTitle contains " - Google Chrome" then
                    -- Handle edge case: just "Google Chrome" without profile suffix (Default profile)
                    set profileName to "Default"
                else if winTitle contains " - " then
                    -- Fallback: use last segment after " - " for non-standard titles
                    set AppleScript's text item delimiters to " - "
                    set parts to text items of winTitle
                    if (count of parts) > 1 then
                        set profileName to last item of parts
                    end if
                end if

                set tabList to {}
                repeat with t from 1 to count of tabs of win
                    set theTab to tab t of win
                    set end of tabList to (URL of theTab)
                end repeat

                -- Join tabs with ^^^
                set AppleScript's text item delimiters to "^^^"
                set tabString to tabList as text

                -- Get actual Chrome window ID (not loop index) for reliable matching
                set winId to id of win
                set activeIdx to active tab index of win
                set end of results to (winId as text) & ":::" & profileName & ":::" & (activeIdx as text) & ":::" & tabString
            end repeat

            -- Join results with ###
            set AppleScript's text item delimiters to "###"
            set resultString to results as text
            set AppleScript's text item delimiters to oldDelim

            return resultString
        end tell
        """))
    }

    @Test("Descriptor scripts preserve both execution representations")
    func buildsWindowDescriptorRepresentations() {
        #expect(ChromeAppleScript.windowDescriptors(
            includeTabURLs: true,
            output: .delimitedText
        ) == expectedChromeScript("""
        tell application "__CHROME__"
          if it is running is false then
            return ""
          end if
          set out to ""
          repeat with w from 1 to count of windows
            set tabURLs to {}
            repeat with t from 1 to count of tabs of window w
              set end of tabURLs to (URL of tab t of window w) as string
            end repeat
            set windowBounds to bounds of window w
            set winLeft to item 1 of windowBounds
            set winTop to item 2 of windowBounds
            set winRight to item 3 of windowBounds
            set winBottom to item 4 of windowBounds
            set winWidth to winRight - winLeft
            set winHeight to winBottom - winTop
            set winId to id of window w
            set winName to name of window w as string
            set activeIndex to active tab index of window w
            set oldDelim to AppleScript's text item delimiters
            set AppleScript's text item delimiters to "^^^"
            set tabString to tabURLs as text
            set AppleScript's text item delimiters to oldDelim
            set boundsString to (winLeft as text) & "," & (winTop as text) & "," & (winWidth as text) & "," & (winHeight as text)
            set out to out & (winId as text) & "\\t" & winName & "\\t" & (activeIndex as text) & "\\t" & boundsString & "\\t" & tabString & "\\n"
          end repeat
          return out
        end tell
        """))

        #expect(ChromeAppleScript.windowDescriptors(
            includeTabURLs: false,
            output: .delimitedText
        ) == expectedChromeScript("""
        tell application "__CHROME__"
          if it is running is false then
            return ""
          end if
          set out to ""
          repeat with w from 1 to count of windows
            set windowBounds to bounds of window w
            set winLeft to item 1 of windowBounds
            set winTop to item 2 of windowBounds
            set winRight to item 3 of windowBounds
            set winBottom to item 4 of windowBounds
            set winWidth to winRight - winLeft
            set winHeight to winBottom - winTop
            set winId to id of window w
            set winName to name of window w as string
            set activeIndex to active tab index of window w
            set boundsString to (winLeft as text) & "," & (winTop as text) & "," & (winWidth as text) & "," & (winHeight as text)
            set out to out & (winId as text) & "\\t" & winName & "\\t" & (activeIndex as text) & "\\t" & boundsString & "\\t" & "" & "\\n"
          end repeat
          return out
        end tell
        """))

        #expect(ChromeAppleScript.windowDescriptors(
            includeTabURLs: true,
            output: .appleEventList
        ) == expectedChromeScript("""
        tell application "__CHROME__"
          if it is running is false then
            return {}
          end if
          set windowData to {}
          repeat with w from 1 to count of windows
            set tabURLs to {}
            repeat with t from 1 to count of tabs of window w
              set end of tabURLs to (URL of tab t of window w) as string
            end repeat
            set windowBounds to bounds of window w
            set end of windowData to {id of window w, name of window w as string, active tab index of window w, tabURLs, windowBounds}
          end repeat
          return windowData
        end tell
        """))

        #expect(ChromeAppleScript.windowDescriptors(
            includeTabURLs: false,
            output: .appleEventList
        ) == expectedChromeScript("""
        tell application "__CHROME__"
          if it is running is false then
            return {}
          end if
          set windowData to {}
          repeat with w from 1 to count of windows
            set windowBounds to bounds of window w
            set end of windowData to {id of window w, name of window w as string, active tab index of window w, {}, windowBounds}
          end repeat
          return windowData
        end tell
        """))
    }

    private func expectedChromeScript(_ template: String) -> String {
        template.replacingOccurrences(of: "__CHROME__", with: "Google Chrome")
    }

    private func expectedBoundsMatchedScript(action: String) -> String {
        let indentedAction = action
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { "                \($0)" }
            .joined(separator: "\n")

        return expectedChromeScript("""
        tell application "__CHROME__"
          if it is running is false then return

          tell application "System Events"
            tell process "Google Chrome"
              set targetWindow to missing value
              repeat with w from 1 to count of windows
                set windowPos to position of window w
                set windowSize to size of window w
                set x to item 1 of windowPos
                set y to item 2 of windowPos
                set width to item 1 of windowSize
                set height to item 2 of windowSize

                if x is 10 and y is 20 and width is 300 and height is 400 then
                  set targetWindow to w
                  exit repeat
                end if
              end repeat

              if targetWindow is missing value then return

              tell application "__CHROME__"
        \(indentedAction)
              end tell
            end tell
          end tell
        end tell
        """)
    }
}
