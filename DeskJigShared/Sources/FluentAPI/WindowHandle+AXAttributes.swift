//  WindowHandle+AXAttributes.swift
//  DeskJigShared

import Foundation
import ApplicationServices

extension WindowHandle {

    /// CGWindowID (window number) for the underlying AX element, when available.
    public var windowId: Int? {
        guard let element = axElement else { return nil }

        var value: CFTypeRef?
        let attribute = "AXWindowNumber" as CFString
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success, let value else { return nil }

        if let number = value as? NSNumber {
            return number.intValue
        }
        if let intValue = value as? Int {
            return intValue
        }

        return nil
    }

    /// Stable-ish identity for the underlying AX element (useful for diffing window lists).
    public var axElementHash: Int? {
        guard let element = axElement else { return nil }
        return Int(CFHash(element))
    }

    /// Best-effort document path for this window using `kAXDocumentAttribute`.
    ///
    /// Many IDEs/editors expose a `file://` URL here that points to the opened workspace or file.
    public var documentPath: String? {
        guard let element = axElement else { return nil }

        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXDocumentAttribute as CFString, &value)
        guard result == .success, let value else { return nil }

        // kAXDocumentAttribute is typically a CFString
        if let docString = value as? String {
            let trimmed = docString.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }

            if trimmed.hasPrefix("file://"), let url = URL(string: trimmed) {
                return url.path
            }
            return trimmed
        }

        return nil
    }
}
