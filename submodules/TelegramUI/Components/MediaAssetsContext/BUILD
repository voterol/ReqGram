load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

swift_library(
    name = "MediaAssetsContext",
    module_name = "MediaAssetsContext",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        "-suppress-warnings",
    ],
    deps = [
        "//submodules/Display",
        "//submodules/SSignalKit/SwiftSignalKit",
    ],
    visibility = [
        "//visibility:public",
    ],
)
