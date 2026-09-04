# Stage 0 probe.
#
# Suite A answered its question on device: the low fixed addresses the PC port
# maps (0x10000000, 0x70000000, 0x80000000) sit inside the 4 GB __PAGEZERO and
# are unreachable. Shrinking __PAGEZERO is not a way out, because dyld refuses
# to dlopen the result, which is how LiveContainer loads a guest app.
#
# Suite B tests the replacement: a 4 GB-aligned window plus vm_remap aliasing.
#
# Configure with the Xcode generator, the same way the real port will be built:
#   cmake -B build-ios -G Xcode -DCMAKE_SYSTEM_NAME=iOS \
#         -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0
cmake_minimum_required(VERSION 3.20)
project(geprobe OBJC)

set(INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/ios/Info.plist")

# variant: a label baked into the report so a screenshot is self-identifying.
function(add_probe_variant target variant)
    add_executable(${target} MACOSX_BUNDLE src/probe.m)

    target_compile_definitions(${target} PRIVATE PROBE_VARIANT="${variant}")
    target_link_libraries(${target} PRIVATE
        "-framework UIKit" "-framework Foundation" "-framework CoreGraphics")

    set_target_properties(${target} PROPERTIES
        MACOSX_BUNDLE_INFO_PLIST "${INFO_PLIST}"
        XCODE_ATTRIBUTE_PRODUCT_BUNDLE_IDENTIFIER "dev.project516.geprobe.${variant}"
        XCODE_ATTRIBUTE_PRODUCT_NAME "${target}"
        XCODE_ATTRIBUTE_TARGETED_DEVICE_FAMILY "1,2"
        XCODE_ATTRIBUTE_IPHONEOS_DEPLOYMENT_TARGET "15.0"
        XCODE_ATTRIBUTE_DEVELOPMENT_TEAM ""
        XCODE_ATTRIBUTE_CODE_SIGN_IDENTITY ""
        XCODE_ATTRIBUTE_CODE_SIGNING_REQUIRED "NO"
        XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED "NO"
        XCODE_ATTRIBUTE_ENABLE_BITCODE "NO")
endfunction()

add_probe_variant(geprobe default)
