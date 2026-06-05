cmake_minimum_required(VERSION 3.16)

project(SourCeEditor VERSION 0.2.0 LANGUAGES CXX OBJCXX)

if(NOT APPLE)
  message(FATAL_ERROR "The GUI build uses native macOS Cocoa. Build this on macOS, or restore src/main.cpp for the terminal version.")
endif()

set(SOURCE_APP_ICON "${CMAKE_CURRENT_SOURCE_DIR}/assets/SourCe.icns")

add_executable(SourCe MACOSX_BUNDLE src/gui_main.mm "${SOURCE_APP_ICON}")
target_compile_features(SourCe PRIVATE cxx_std_17)
target_link_libraries(SourCe PRIVATE "-framework Cocoa")
set_source_files_properties("${SOURCE_APP_ICON}" PROPERTIES MACOSX_PACKAGE_LOCATION "Resources")

set_target_properties(SourCe PROPERTIES
  MACOSX_BUNDLE_GUI_IDENTIFIER "art.source.sour-ce"
  MACOSX_BUNDLE_BUNDLE_NAME "SourCe"
  MACOSX_BUNDLE_DISPLAY_NAME "SourCe"
  MACOSX_BUNDLE_ICON_FILE "SourCe.icns"
  MACOSX_BUNDLE_SHORT_VERSION_STRING "${PROJECT_VERSION}"
  MACOSX_BUNDLE_BUNDLE_VERSION "${PROJECT_VERSION}"
  MACOSX_BUNDLE_COPYRIGHT "SourCe"
)

target_compile_definitions(SourCe
  PRIVATE
    JUICY_SOURCE_PATH="${CMAKE_CURRENT_SOURCE_DIR}/src/gui_main.mm"
    JUICY_VERSION="${PROJECT_VERSION}"
)

if(CMAKE_CXX_COMPILER_ID MATCHES "Clang|GNU")
  target_compile_options(SourCe PRIVATE -Wall -Wextra -Wpedantic)
endif()
target_compile_options(SourCe PRIVATE "$<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>")
