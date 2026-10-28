import Foundation

/// A path made safe to hand to a shell as one word.
///
/// Two strings Burnline writes are run through a shell it does not control:
/// the statusline `command` (Claude Code's) and the sign-in `.command` script
/// (`/bin/sh`). An unquoted path with a space split into two words and failed.
///
/// Quoted only when it has to be. Every install so far lives at a path made of
/// these characters, and its settings file must keep reading as `.configured`
/// rather than as a different copy.
enum ShellQuote {
    private static let safe = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/._-+@%:,=")

    static func word(_ path: String) -> String {
        if !path.isEmpty, path.allSatisfy(safe.contains) { return path }
        // Inside single quotes nothing is special except the quote itself,
        // which closes, is escaped, and reopens.
        return "'" + path.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}
