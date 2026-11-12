load("@build_bazel_rules_apple//apple:apple.bzl", "apple_dynamic_xcframework_import")

apple_dynamic_xcframework_import(
    name = "Python",
    xcframework_imports = glob(["vendor/Python.xcframework/**/Python.framework/**", "vendor/Python.xcframework/Info.plist"]),
    visibility = ["//visibility:public"],
)

exports_files(["vendor/python313.zip", "vendor/Python.xcframework/lib/python3.13/LICENSE.txt", "BEEWARE-LICENSE.txt"])
