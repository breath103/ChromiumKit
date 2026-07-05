@_exported import ChromiumViewObjC
import Foundation

public extension ChromiumWebView {
    /// Decode a typed return value from JS. Swift already auto-generates an
    /// `evaluateJavaScript(_:) async throws -> Any` from the ObjC method.
    func evaluateJavaScript<T: Decodable>(_ script: String, as: T.Type) async throws -> T {
        let raw: Any? = try await withCheckedThrowingContinuation { c in
            self.evaluateJavaScript(script) { value, error in
                if let error { c.resume(throwing: error) } else { c.resume(returning: value) }
            }
        }
        guard let raw, !(raw is NSNull) else {
            throw NSError(
                domain: "ChromiumView",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: "JS returned undefined/null"]
            )
        }
        // Re-encode through JSON to feed JSONDecoder. Handles dicts/arrays/scalars.
        let data: Data
        if JSONSerialization.isValidJSONObject(raw) {
            data = try JSONSerialization.data(withJSONObject: raw)
        } else if let n = raw as? NSNumber {
            data = try JSONSerialization.data(withJSONObject: [n], options: [.fragmentsAllowed])
            return try JSONDecoder().decode([T].self, from: data)[0]
        } else if let s = raw as? String {
            data = try JSONSerialization.data(withJSONObject: [s], options: [.fragmentsAllowed])
            return try JSONDecoder().decode([T].self, from: data)[0]
        } else {
            throw NSError(
                domain: "ChromiumView",
                code: 6,
                userInfo: [NSLocalizedDescriptionKey: "unsupported JS return type"]
            )
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

public extension ChromiumConfiguration {
    /// Convenience initializer for the most common config shape.
    convenience init(
        userAgent: String? = nil,
        locale: String? = nil,
        cachePath: URL? = nil,
        sandboxDisabled: Bool = true,
        useMockKeychain: Bool = false
    ) {
        self.init()
        self.userAgent = userAgent
        self.locale = locale
        self.cachePath = cachePath
        self.sandboxDisabled = sandboxDisabled
        self.useMockKeychain = useMockKeychain
    }
}
