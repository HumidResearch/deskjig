//  AlertInfo.swift
//  DeskJigShared

/// The contents of an alert
public struct AlertInfo: Identifiable {
    public let id = UUID()
    public let title: String
    public let message: String
    
    public init(title: String, message: String) {
        self.title = title
        self.message = message
    }
}
