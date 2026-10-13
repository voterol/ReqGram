load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

swift_library(
    name = "InAppPurchaseManager",
    module_name = "InAppPurchaseManager",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    # Legacy StoreKit 1 APIs are deprecated by the current SDK.
    copts = [
        "-suppress-warnings",
    ],
    deps = [
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/TelegramCore:TelegramCore",
        "//submodules/TelegramStringFormatting:TelegramStringFormatting",
        "//submodules/TelegramUIPreferences:TelegramUIPreferences",
        "//submodules/PersistentStringHash:PersistentStringHash",
    ],
    visibility = [
        "//visibility:public",
    ],
)
