load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")
load("@build_bazel_rules_apple//apple:ios.bzl", "ios_unit_test")
load("@build_bazel_rules_apple//apple/testing/default_runner:ios_test_runner.bzl", "ios_test_runner")

filegroup(
    name = "SGUIAssets",
    srcs = glob(["Images.xcassets/**"]),
    visibility = ["//visibility:public"],
)

swift_library(
    name = "SGSettingsUI",
    module_name = "SGSettingsUI",
    srcs = glob([
    "Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//Swiftgram/SGItemListUI:SGItemListUI",
        "//Swiftgram/SGLogging:SGLogging",
        "//Swiftgram/SGSimpleSettings:SGSimpleSettings",
        "//Swiftgram/SGScamRegistry:SGScamRegistry",
        "//Swiftgram/ReqGramPythonRuntime",
        "//Swiftgram/ReqGramNativeBridge",
        "//Swiftgram/SGStrings:SGStrings",
        "//Swiftgram/AyuGram:AyuGram",
#        "//Swiftgram/SGAPI:SGAPI",
        "//Swiftgram/SGAPIToken:SGAPIToken",
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/Display:Display",
        "//submodules/Postbox:Postbox",
        "//submodules/TelegramCore:TelegramCore",
        "//submodules/TelegramApi:TelegramApi",
        "//submodules/MtProtoKit:MtProtoKit",
        "//submodules/TelegramPresentationData:TelegramPresentationData",
        "//submodules/TelegramUIPreferences:TelegramUIPreferences",
        "//submodules/ItemListUI:ItemListUI",
        "//submodules/PresentationDataUtils:PresentationDataUtils",
        "//submodules/OverlayStatusController:OverlayStatusController",
        "//submodules/AccountContext:AccountContext",
        "//submodules/AppBundle:AppBundle",
        "//submodules/ComponentFlow:ComponentFlow",
        "//submodules/TelegramUI/Components/AlertComponent:AlertComponent",
        "//submodules/TelegramUI/Components/Settings/PeerNameColorScreen",
        "//submodules/UndoUI:UndoUI",
        "//submodules/PromptUI:PromptUI",
        "//third-party/ZipArchive:ZipArchive",
    ],
    visibility = [
        "//visibility:public",
    ],
)

swift_library(
    name = "SGSettingsUIMTProtoTestsLib",
    testonly = True,
    srcs = glob([
        "Tests/ReqGramMTProtoTests.swift",
        "Tests/TgwsRouteTests.swift",
    ]),
    deps = [
        ":SGSettingsUI",
        "//submodules/TelegramCore:TelegramCore",
        "//Swiftgram/SGSimpleSettings:SGSimpleSettings",
    ],
)

ios_test_runner(
    name = "SGSettingsUIMTProtoTestRunner",
    device_type = "iPhone 17",
    os_version = "26.5",
)

ios_unit_test(
    name = "SGSettingsUIMTProtoTests",
    minimum_os_version = "13.0",
    runner = ":SGSettingsUIMTProtoTestRunner",
    deps = [
        ":SGSettingsUIMTProtoTestsLib",
    ],
    visibility = [
        "//visibility:public",
    ],
)
