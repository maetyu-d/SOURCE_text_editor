cmake_minimum_required(VERSION 3.16)

project(SourCeEditor VERSION 0.2.0 LANGUAGES CXX OBJCXX)

if(NOT APPLE)
  message(FATAL_ERROR "The GUI build uses native macOS Cocoa. Build this on macOS, or restore src/main.cpp for the terminal version.")
endif()

add_executable(SourCe src/gui_main.mm)
target_compile_features(SourCe PRIVATE cxx_std_17)
target_link_libraries(SourCe PRIVATE "-framework Cocoa")

target_compile_definitions(SourCe
  PRIVATE
    JUICY_SOURCE_PATH="${CMAKE_CURRENT_SOURCE_DIR}/src/gui_main.mm"
    JUICY_VERSION="${PROJECT_VERSION}"
)

if(CMAKE_CXX_COMPILER_ID MATCHES "Clang|GNU")
  target_compile_options(SourCe PRIVATE -Wall -Wextra -Wpedantic)
endif()
target_compile_options(SourCe PRIVATE "$<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>")
