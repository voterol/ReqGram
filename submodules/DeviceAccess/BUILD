load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

swift_library(
    name = "DeviceAccess",
    module_name = "DeviceAccess",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    # Legacy AVFoundation/CoreLocation APIs are deprecated by the current SDK.
    copts = [
        "-suppress-warnings",
    ],
    deps = [
        "//submodules/TelegramCore:TelegramCore",
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/Display:Display",
        "//submodules/AccountContext:AccountContext",
        "//submodules/TelegramPresentationData:TelegramPresentationData",
        "//submodules/LegacyComponents:LegacyComponents",
    ],
    visibility = [
        "//visibility:public",
    ],
)
