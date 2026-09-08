load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

swift_library(
    name = "AyuGram",
    module_name = "AyuGram",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    # AyuGram currently uses UIKit capture APIs that are deprecated by the
    # iOS 26 SDK. Keep this target buildable while the scene-based capture
    # implementation is evaluated separately.
    copts = [
        "-suppress-warnings",
    ],
    deps = [
        "//Swiftgram/SGLogging:SGLogging",
        "//Swiftgram/SGSimpleSettings:SGSimpleSettings",
    ],
    visibility = [
        "//visibility:public",
    ],
)
