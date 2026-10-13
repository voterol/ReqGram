import Foundation

func expect(_ value: @autoclosure () -> Bool, _ message: String) {
    precondition(value(), message)
}
let valid = Data(#"{"tag_name":"v1.2.3","draft":false,"prerelease":false,"body":"ignored","assets":[{"browser_download_url":"https://evil.example/payload.exe"}]}"#.utf8)
let date = Date(timeIntervalSince1970: 100)
expect(TgwsProxyReleaseChecker.decode(valid, now: date)?.tag == "v1.2.3", "valid release")
expect(TgwsProxyReleaseChecker.decode(valid, now: date)?.checkedAt == date, "check timestamp")
for payload in [
    #"{"tag_name":"v1\nsecret","draft":false,"prerelease":false}"#,
    #"{"tag_name":"<script>","draft":false,"prerelease":false}"#,
    #"{"tag_name":"v2","draft":true,"prerelease":false}"#,
    #"{"tag_name":"v2","draft":false,"prerelease":true}"#,
    #"{"tag_name":"v2"}"#,
    "[]", "null", "invalid"
] {
    expect(TgwsProxyReleaseChecker.decode(Data(payload.utf8)) == nil, "reject malformed/untrusted metadata")
}
expect(!TgwsProxyReleaseChecker.validTag(String(repeating: "a", count: 81)), "tag bound")
expect(!TgwsProxyReleaseChecker.validTag(""), "empty tag")
expect(TgwsProxyReleaseChecker.decode(Data(repeating: 32, count: 65537)) == nil, "body bound")
let suite = "SettingsUI.TgwsRelease.tests.\(UUID().uuidString)"
let defaults = UserDefaults(suiteName: suite)!
defer { defaults.removePersistentDomain(forName: suite) }
let checker = TgwsProxyReleaseChecker(defaults: defaults)
expect(!checker.automatic, "automatic defaults to opt-in")
checker.check(manual: false)
expect(!checker.checking, "opt-out performs no request")
checker.automatic = true
expect(TgwsProxyReleaseChecker(defaults: defaults).automatic, "preference persists")
defaults.set(try JSONEncoder().encode(TgwsProxyReleaseChecker.Release(tag: "v1.0", checkedAt: date)), forKey: "SettingsUI.tgws.release.cache.v1")
expect(TgwsProxyReleaseChecker(defaults: defaults).cached?.tag == "v1.0", "cache persists")
defaults.set(try JSONEncoder().encode(TgwsProxyReleaseChecker.Release(tag: "bad\nvalue", checkedAt: date)), forKey: "SettingsUI.tgws.release.cache.v1")
expect(TgwsProxyReleaseChecker(defaults: defaults).cached == nil, "cache validated")
print("Tgws release metadata/cache tests passed (offline)")
