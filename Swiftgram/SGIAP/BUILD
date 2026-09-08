load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

swift_library(
    name = "SGIAP",
    module_name = "SGIAP",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    # Legacy StoreKit APIs emit deprecation warnings under newer SDKs.
    # Keep this module buildable without changing its behavior; migrate separately.
    copts = [
        "-suppress-warnings",
    ],
    deps = [
        "//Swiftgram/SGLogging:SGLogging",
        "//Swiftgram/SGConfig:SGConfig",
        "//submodules/AppBundle:AppBundle",
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
    ],
    visibility = [
        "//visibility:public",
    ],
)
