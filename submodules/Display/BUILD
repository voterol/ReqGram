load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

sgsrc = [
    "//Swiftgram/SGAppBadgeOffset:SGAppBadgeOffset"
]

sgdeps = [
    "//submodules/Utils/DeviceModel",
    "//Swiftgram/SGSimpleSettings:SGSimpleSettings",
]

swift_library(
    name = "Display",
    module_name = "Display",
    srcs = sgsrc + glob([
        "Source/**/*.swift",
    ]),
    # Legacy UIKit APIs in this module are deprecated by the current SDK.
    # Keep the module buildable while the APIs are migrated.
    copts = [
        "-suppress-warnings",
    ],
    deps = sgdeps + [
    	"//submodules/ObjCRuntimeUtils:ObjCRuntimeUtils",
    	"//submodules/UIKitRuntimeUtils:UIKitRuntimeUtils",
        "//submodules/AppBundle:AppBundle",
    	"//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/Markdown:Markdown",
        "//submodules/AsyncDisplayKit:AsyncDisplayKit",
    ],
    visibility = [
        "//visibility:public",
    ],
)
