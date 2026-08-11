//
//  NSAlert.swift
//  DeskJigShared
//

import AppKit

extension NSAlert {
    public static func show(title: String, message: String, style: NSAlert.Style = .informational) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = style
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
