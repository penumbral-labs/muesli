import Foundation

enum ModelDownloadPathSafety {
    static func isSafeRelativePath(_ path: String) -> Bool {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return !path.isEmpty
            && !path.hasPrefix("/")
            && !path.contains("\\")
            && components.allSatisfy { $0 != "." && $0 != ".." && !$0.isEmpty }
    }
}
