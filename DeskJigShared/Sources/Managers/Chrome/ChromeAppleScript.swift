//  ChromeAppleScript.swift
//  DeskJigShared

import Foundation

/// Pure builders for the AppleScript commands used to inspect and control Google Chrome.
///
/// This type only generates source strings. Callers remain responsible for executing those
/// strings through `AppleScriptRunner` using the execution mode appropriate to their context.
public enum ChromeAppleScript {

    public enum WindowDescriptorOutput {
        case delimitedText
        case appleEventList
    }

    /// Opens Chrome's extension-management page in the active profile.
    public static let openExtensionsPage = """
    tell application "Google Chrome"
        activate
        open location "chrome://extensions"
    end tell
    """

    /// Replaces the active tab in a window selected by its 1-based ordinal, then appends tabs.
    public static func replaceActiveTabAndAppend(_ urls: [String], inWindowIndex windowIndex: Int) -> String {
        var script = """
        tell application "Google Chrome"
            set targetWindow to window \(windowIndex)
        """

        for (index, url) in urls.enumerated() {
            if index == 0 {
                script += """

                    tell targetWindow
                        set URL of active tab to \(quoted(url))
                    end tell
                """
            } else {
                script += """

                    tell targetWindow
                        make new tab with properties {URL:\(quoted(url))}
                    end tell
                """
            }
        }

        script += """

        end tell
        """
        return script
    }

    /// Creates a new front window in the active profile and populates it with the supplied URLs.
    public static func openNewFrontWindow(urls: [String]) -> String {
        var script = """
        tell application "Google Chrome"
            activate
            make new window
        """

        for (index, url) in urls.enumerated() {
            if index == 0 {
                script += """

                    tell front window
                        set URL of active tab to \(quoted(url))
                    end tell
                """
            } else {
                script += """

                    tell front window
                        make new tab with properties {URL:\(quoted(url))}
                    end tell
                """
            }
        }

        script += """

        end tell
        """
        return script
    }

    /// Returns `bounds:::profile:::url^^^url###...` for every Chrome window.
    public static let windowTabDataWithBoundsAndProfiles = """
    tell application "Google Chrome"
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
    """

    /// Returns `id:::profile:::activeIndex:::url^^^url###...` for every Chrome window.
    public static let windowSnapshotData = """
    tell application "Google Chrome"
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
    """

    /// Captures active tab, bounds, and URLs for one Chrome window ID.
    public static func tabData(inWindowID windowID: Int) -> String {
        """
        tell application "Google Chrome"
          if it is running is false then
            return ""
          end if

          try
            set chromeWindow to window id \(windowID)
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
        """
    }

    /// Appends tabs to a Chrome window selected by its stable AppleScript window ID.
    public static func appendTabs(_ urls: [String], toWindowID windowID: Int) -> String {
        let urlList = urls.map(quoted).joined(separator: ", ")
        return """
        tell application "Google Chrome"
          if it is running is false then return

          try
            set chromeWindow to window id \(windowID)
            set urlsToOpen to {\(urlList)}
            repeat with candidate in urlsToOpen
              set candidateURL to candidate as string
              make new tab at end of tabs of chromeWindow with properties {URL:candidateURL}
            end repeat
          on error errMsg
            return "Error: " & errMsg
          end try
        end tell
        """
    }

    public static func setActiveTab(index: Int, inWindowID windowID: Int) -> String {
        """
        tell application "Google Chrome"
          if it is running is false then return

          try
            set chromeWindow to window id \(windowID)
            set active tab index of chromeWindow to \(index)
          on error errMsg
            return "Error: " & errMsg
          end try
        end tell
        """
    }

    public static func setActiveTabURL(_ url: String, inWindowID windowID: Int) -> String {
        """
        tell application "Google Chrome"
          if it is running is false then return

          try
            set chromeWindow to window id \(windowID)
            tell chromeWindow
              set URL of active tab to \(quoted(url))
              set index to 1
            end tell
            activate
          on error errMsg
            return "Error: " & errMsg
          end try
        end tell
        """
    }

    public static func closeWindow(windowID: Int) -> String {
        """
        tell application "Google Chrome"
          if it is running is false then return

          try
            set chromeWindow to window id \(windowID)
            close chromeWindow
          on error errMsg
            return "Error: " & errMsg
          end try
        end tell
        """
    }

    public static func setBounds(ofWindowID windowID: Int, to bounds: CGRect) -> String {
        let edges = roundedEdges(of: bounds)
        return """
        tell application "Google Chrome"
          if it is running is false then return

          try
            set chromeWindow to window id \(windowID)
            set bounds of chromeWindow to {\(edges.left), \(edges.top), \(edges.right), \(edges.bottom)}
          on error errMsg
            return "Error: " & errMsg
          end try
        end tell
        """
    }

    /// Opens URLs in a new window, optionally positions it, and returns its stable window ID.
    public static func openURLsInNewWindow(
        _ urls: [String],
        bounds: CGRect? = nil,
        activate: Bool = true
    ) -> String {
        precondition(!urls.isEmpty, "At least one URL is required")

        var script = """
        tell application "Google Chrome"
          set newWin to make new window
          set URL of active tab of newWin to \(quoted(urls[0]))
        """

        for url in urls.dropFirst() {
            script += """

              make new tab at end of tabs of newWin with properties {URL: \(quoted(url))}
            """
        }

        if let bounds {
            let edges = roundedEdges(of: bounds)
            script += """

              set bounds of newWin to {\(edges.left), \(edges.top), \(edges.right), \(edges.bottom)}
            """
        }

        if activate {
            script += """

              set index of newWin to 1
              activate
            """
        }

        script += """

          return id of newWin
        end tell
        """
        return script
    }

    /// Closes a list of 1-based tab indices in the caller-provided order.
    public static func closeTabs(at indices: [Int], inWindowID windowID: Int) -> String {
        let indexList = indices.map(String.init).joined(separator: ", ")
        return """
        tell application "Google Chrome"
          if it is running is false then return

          try
            set chromeWindow to window id \(windowID)
            repeat with idxRef in {\(indexList)}
              set idx to idxRef as integer
              if (count of tabs of chromeWindow) >= idx then
                close tab idx of chromeWindow
              end if
            end repeat
          on error errMsg
            return "Error: " & errMsg
          end try
        end tell
        """
    }

    public static func appendTabs(_ urls: [String], matchingBounds bounds: CGRect) -> String {
        let urlList = urls.map(quoted).joined(separator: ", ")
        return scriptTargetingWindow(matching: bounds, action: """
        set chromeWindow to window (targetWindow as integer)
        set urlsToOpen to {\(urlList)}
        repeat with candidate in urlsToOpen
          set candidateURL to candidate as string
          make new tab at end of tabs of chromeWindow with properties {URL:candidateURL}
        end repeat
        """)
    }

    public static func setActiveTab(index: Int, matchingBounds bounds: CGRect) -> String {
        scriptTargetingWindow(matching: bounds, action: """
        set chromeWindow to window (targetWindow as integer)
        set active tab index of chromeWindow to \(index)
        """)
    }

    public static func closeTab(at index: Int, matchingBounds bounds: CGRect) -> String {
        scriptTargetingWindow(matching: bounds, action: """
        set chromeWindow to window (targetWindow as integer)
        if (count of tabs of chromeWindow) >= \(index) then
          close tab \(index) of chromeWindow
        end if
        """)
    }

    /// Enumerates Chrome window descriptors in the representation expected by the execution mode.
    public static func windowDescriptors(
        includeTabURLs: Bool,
        output: WindowDescriptorOutput
    ) -> String {
        switch output {
        case .delimitedText:
            return delimitedWindowDescriptors(includeTabURLs: includeTabURLs)
        case .appleEventList:
            return appleEventListWindowDescriptors(includeTabURLs: includeTabURLs)
        }
    }

    private static func delimitedWindowDescriptors(includeTabURLs: Bool) -> String {
        if includeTabURLs {
            return """
            tell application "Google Chrome"
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
            """
        }

        return """
        tell application "Google Chrome"
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
        """
    }

    private static func appleEventListWindowDescriptors(includeTabURLs: Bool) -> String {
        if includeTabURLs {
            return """
            tell application "Google Chrome"
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
            """
        }

        return """
        tell application "Google Chrome"
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
        """
    }

    private static func scriptTargetingWindow(matching bounds: CGRect, action: String) -> String {
        let x = Int(bounds.origin.x)
        let y = Int(bounds.origin.y)
        let width = Int(bounds.size.width)
        let height = Int(bounds.size.height)
        let indentedAction = action
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { "                \($0)" }
            .joined(separator: "\n")

        return """
        tell application "Google Chrome"
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

                if x is \(x) and y is \(y) and width is \(width) and height is \(height) then
                  set targetWindow to w
                  exit repeat
                end if
              end repeat

              if targetWindow is missing value then return

              tell application "Google Chrome"
        \(indentedAction)
              end tell
            end tell
          end tell
        end tell
        """
    }

    private static func quoted(_ value: String) -> String {
        "\"\(escaped(value))\""
    }

    private static func escaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func roundedEdges(of bounds: CGRect) -> (left: Int, top: Int, right: Int, bottom: Int) {
        (
            left: Int(bounds.minX.rounded()),
            top: Int(bounds.minY.rounded()),
            right: Int(bounds.maxX.rounded()),
            bottom: Int(bounds.maxY.rounded())
        )
    }
}
