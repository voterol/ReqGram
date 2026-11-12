load("@build_bazel_rules_apple//apple:resources.bzl", "apple_resource_bundle")
load("@build_bazel_rules_apple//apple:ios.bzl", "ios_application")
load("@rules_cc//cc:objc_library.bzl", "objc_library")

apple_resource_bundle(
    name = "ReqGramPythonResources",
    resources = [
        "Resources/reqgram_smoke.py",
        "Resources/FLOWSEAL-LICENSE.txt",
        "//third-party/PythonRuntime:vendor/python313.zip",
        "//third-party/PythonRuntime:vendor/Python.xcframework/lib/python3.13/LICENSE.txt",
        "//third-party/PythonRuntime:BEEWARE-LICENSE.txt",
    ],
)

objc_library(
    name = "ReqGramPythonRuntime",
    srcs = ["Sources/RGPythonRuntime.m", "Sources/RGTgwsCrypto.m", "Sources/RGTgwsService.m", "Sources/RGTgwsIPTransport.m"],
    hdrs = ["Sources/RGPythonRuntime.h", "Sources/RGTgwsCrypto.h", "Sources/RGTgwsService.h"],
    textual_hdrs = ["Sources/RGTgwsIPTransport.h"],
    enable_modules = True,
    module_name = "ReqGramPythonRuntime",
    sdk_frameworks = ["Foundation", "Security", "UIKit", "Network"],
    deps = [":ReqGramPythonResources", "//third-party/PythonRuntime:Python"],
    visibility = ["//visibility:public"],
)

objc_library(
    name = "SmokeMain",
    srcs = ["Tests/main.m"],
    includes = ["Sources"],
    sdk_frameworks = ["UIKit"],
    deps = [":ReqGramPythonRuntime"],
)

ios_application(
    name = "ReqGramPythonSmoke",
    bundle_id = "local.reqgram.python.smoke",
    families = ["iphone", "ipad"],
    minimum_os_version = "14.0",
    infoplists = ["Tests/Info.plist"],
    deps = [":SmokeMain"],
)
