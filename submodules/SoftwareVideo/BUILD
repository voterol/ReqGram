load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

swift_library(
    name = "SoftwareVideo",
    module_name = "SoftwareVideo",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    # Legacy AVFoundation APIs are deprecated by the current SDK.
    copts = [
        "-suppress-warnings",
    ],
    deps = [
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/AsyncDisplayKit:AsyncDisplayKit",
        "//submodules/Display:Display",
        "//submodules/TelegramCore:TelegramCore",
        "//submodules/AccountContext:AccountContext",
        "//submodules/MediaPlayer:UniversalMediaPlayer",
    ],
    visibility = [
        "//visibility:public",
    ],
)
