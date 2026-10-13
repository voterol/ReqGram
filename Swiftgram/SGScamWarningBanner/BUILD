load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

swift_library(
    name = "SGScamWarningBanner",
    module_name = "SGScamWarningBanner",
    srcs = glob(["Sources/**/*.swift"]),
    deps = [
        "//submodules/Display:Display",
        "//submodules/TelegramPresentationData:TelegramPresentationData",
        "//submodules/ComponentFlow:ComponentFlow",
        "//submodules/Components/ComponentDisplayAdapters:ComponentDisplayAdapters",
        "//Swiftgram/SGStrings:SGStrings",
    ],
    visibility = ["//visibility:public"],
)
