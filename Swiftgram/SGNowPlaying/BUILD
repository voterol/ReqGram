load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")
load("@build_bazel_rules_apple//apple:resources.bzl", "apple_resource_bundle")

# Fonts for the Now Playing send card, carried over from the original plugin
# package (Onest — SIL OFL; YS Music — Yandex brand font, private build only).
apple_resource_bundle(
    name = "SGNowPlayingResources",
    resources = [
        "Resources/Fonts/YSMusic-Regular.ttf",
        "Resources/Fonts/Onest-Regular.ttf",
        "Resources/Fonts/Onest-Bold.ttf",
    ],
    visibility = ["//visibility:public"],
)

swift_library(
    name = "SGNowPlaying",
    module_name = "SGNowPlaying",
    srcs = glob(["Sources/**/*.swift"]),
    deps = [
        "//submodules/AccountContext:AccountContext",
        "//submodules/Display:Display",
        "//submodules/Postbox:Postbox",
        "//submodules/TelegramCore:TelegramCore",
        "//submodules/TelegramPresentationData:TelegramPresentationData",
        "//submodules/PresentationDataUtils:PresentationDataUtils",
        "//submodules/QrCode:QrCode",
        "//submodules/ShareController:ShareController",
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//Swiftgram/SGStrings:SGStrings",
        ":SGNowPlayingResources",
    ],
    visibility = ["//visibility:public"],
)
