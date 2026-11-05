import Foundation

enum PreflightRouting {
    static func requiresAttention(_ result:PreflightResult)->Bool {
        !result.ok || result.messages.contains {message in
            let prefix=message.trimmingCharacters(in:.whitespacesAndNewlines).uppercased()
            return prefix.hasPrefix("WARNING") || prefix.hasPrefix("FAIL")
        }
    }
}
