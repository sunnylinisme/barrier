cmake_minimum_required(VERSION 3.20)
project(BarrierNativeDropProbe LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 14)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# Standalone: building this probe does not require Qt or Barrier's old dependencies.
if(APPLE)
    enable_language(OBJCXX)
    add_executable(native-drop-probe MACOSX_BUNDLE MacProbe.mm)
    target_compile_options(native-drop-probe PRIVATE -fobjc-arc -Wall -Wextra)
    target_link_libraries(native-drop-probe PRIVATE "-framework Cocoa")
    set_target_properties(native-drop-probe PROPERTIES
        MACOSX_BUNDLE_BUNDLE_NAME "Barrier Drop Probe"
        MACOSX_BUNDLE_GUI_IDENTIFIER "org.barrier.native-drop-probe")
elseif(WIN32)
    add_executable(native-drop-probe WindowsProbe.cpp)
    target_include_directories(native-drop-probe PRIVATE ../../src/lib)
    target_compile_definitions(native-drop-probe PRIVATE UNICODE _UNICODE NOMINMAX)
    target_compile_options(native-drop-probe PRIVATE /W4 /utf-8 /EHsc)
    target_link_libraries(native-drop-probe PRIVATE ole32 shell32 shlwapi user32 gdi32 uuid)
else()
    message(FATAL_ERROR "This native drag-and-drop probe targets macOS and Windows only")
endif()

enable_testing()
add_test(NAME native-drop-contract COMMAND native-drop-probe --self-test)
