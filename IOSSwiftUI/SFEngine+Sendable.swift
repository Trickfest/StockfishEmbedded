import Foundation

// SFEngine uses internal threads but is invoked from controlled contexts in this app.
// Mark it @unchecked Sendable so we can pass it across concurrency boundaries safely.
extension SFEngine: @unchecked Sendable {}
