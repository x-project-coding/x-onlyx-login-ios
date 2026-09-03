import Foundation

/// The link a creator receives: `onlyx-connect://open?c=<claim>`.
///
/// Its only job is to carry the claim. Everything else — which account, which proxy, which identity
/// — comes back from the API when the claim is spent, so a leaked link tells an attacker nothing but
/// a 15-minute single-use token, and nothing in it can point the app at a different server. Mirrors
/// src/deep-link.js: every shape that still names one well-formed claim is accepted; anything else
/// is not a link.
public enum DeepLink {
    /// A claim is 8–512 URL-safe characters, the same shape the server mints (CLAIM_SHAPE).
    static func isClaimShaped(_ claim: String) -> Bool {
        guard (8...512).contains(claim.count) else { return false }
        return claim.allSatisfy { c in
            c.isASCII && (c.isLetter || c.isNumber || c == "_" || c == "-")
        }
    }

    /// The claim inside a deep link, or nil when the string is not one of ours.
    public static func parse(_ raw: String) -> String? {
        // Trim whitespace and a single layer of wrapping quotes, as the shell sometimes adds.
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count >= 2, let first = text.first, let last = text.last,
           (first == "\"" || first == "'"), first == last {
            text = String(text.dropFirst().dropLast())
        }
        guard text.lowercased().hasPrefix("\(Config.scheme):") else { return nil }
        guard let comps = URLComponents(string: text) else { return nil }
        // `onlyx-connect://open?c=` parses with host "open"; `onlyx-connect:open?c=` with path "open".
        let hostOrPath = comps.host ?? comps.path
        let action = hostOrPath.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        guard action == "open" else { return nil }
        guard let claim = comps.queryItems?.first(where: { $0.name == "c" })?.value,
              isClaimShaped(claim) else { return nil }
        return claim
    }
}
