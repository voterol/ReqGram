load("@rules_cc//cc:objc_library.bzl", "objc_library")

objc_library(
    name = "ReqGramNativeBridge",
    srcs = ["Sources/RGNativeBridgeSession.m"],
    hdrs = ["Sources/RGNativeBridgeSession.h"],
    enable_modules = True,
    module_name = "ReqGramNativeBridge",
    sdk_frameworks = ["AVFAudio", "Foundation", "MediaPlayer", "UIKit"],
    visibility = ["//visibility:public"],
)
