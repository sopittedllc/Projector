//
//  DebugLog.swift
//  Projector
//
//  Debug logging utility that only compiles in DEBUG builds.
//  Prevents logging overhead in release builds.
//

import Foundation

/// Debug logging function that only executes in DEBUG builds.
/// Use this instead of NSLog for development logging.
///
/// - Parameters:
///   - message: The message to log (autoclosure for lazy evaluation)
///   - file: Source file name (auto-filled)
///   - function: Function name (auto-filled)
///   - line: Line number (auto-filled)
@inline(__always)
func debugLog(
    _ message: @autoclosure () -> String,
    file: String = #file,
    function: String = #function,
    line: Int = #line
) {
    #if DEBUG
    let filename = (file as NSString).lastPathComponent
    NSLog(">>> [\(filename):\(line)] \(function): \(message())")
    #endif
}

/// Simplified debug log without file/function context.
/// Use for simple status messages.
@inline(__always)
func debugPrint(_ message: @autoclosure () -> String) {
    #if DEBUG
    NSLog(">>> \(message())")
    #endif
}
