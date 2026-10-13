load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

swift_library(
    name = "ComponentFlow",
    module_name = "ComponentFlow",
    srcs = glob([
        "Source/**/*.swift",
    ]),
    # Legacy UIKit APIs in this module are deprecated by the current SDK.
    copts = [
        "-suppress-warnings",
    ],
    deps = [
        "//submodules/Display",
        "//submodules/UIKitRuntimeUtils",
    ],
    visibility = [
        "//visibility:public",
    ],
)
