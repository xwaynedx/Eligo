import Foundation

enum BundleDisplayName {
    static func resolve(bundle: Bundle, appURL: URL? = nil, fallback: String) -> String {
        if let displayName = nonEmptyValue(bundle.object(forInfoDictionaryKey: "CFBundleDisplayName")) {
            return displayName
        }

        if let bundleName = nonEmptyValue(bundle.object(forInfoDictionaryKey: "CFBundleName")) {
            return bundleName
        }

        if let appURL {
            let fileName = appURL.deletingPathExtension().lastPathComponent
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !fileName.isEmpty {
                return fileName
            }
        }

        return fallback
    }

    private static func nonEmptyValue(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
