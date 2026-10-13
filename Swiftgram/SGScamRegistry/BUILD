load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

swift_library(
    name = "SGScamRegistry",
    module_name = "SGScamRegistry",
    srcs = glob(["Sources/**/*.swift"]),
    deps = [
        "//Swiftgram/SGSimpleSettings:SGSimpleSettings",
        "//submodules/AccountContext:AccountContext",
        "//submodules/TelegramApi:TelegramApi",
        "//submodules/TelegramCore:TelegramCore",
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
    ],
    visibility = ["//visibility:public"],
)
