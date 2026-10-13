import Foundation

public func sgActionRequestHandlerSanitizer(_ url: URL) -> URL {
    guard url.scheme?.lowercased() == "sg",
          let outer = URLComponents(url: url, resolvingAgainstBaseURL: false),
          outer.user == nil, outer.password == nil,
          outer.host?.lowercased() == "parseurl",
          outer.path.isEmpty, outer.fragment == nil,
          let items = outer.queryItems, items.count == 1,
          items[0].name == "url", let value = items[0].value,
          let decoded = URL(string: value),
          let inner = URLComponents(url: decoded, resolvingAgainstBaseURL: false),
          inner.user == nil, inner.password == nil,
          let scheme = inner.scheme?.lowercased() else {
        return url
    }

    if scheme == "https" {
        guard let host = inner.host, !host.isEmpty else {
            return url
        }
        return decoded
    }

    guard inner.query == nil, inner.fragment == nil else {
        return url
    }
    if scheme == "reqgram" {
        switch (inner.host?.lowercased(), inner.path) {
        case ("support", ""), ("ayu", "/support"), ("extera", "/support"):
            return decoded
        default:
            return url
        }
    }
    if scheme == "tg" {
        switch (inner.host?.lowercased(), inner.path) {
        case ("support", ""), ("ayu", "/support"), ("extera", "/support"):
            return decoded
        default:
            return url
        }
    }
    return url
}
