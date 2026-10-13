# The Flutter tooling requires a version of Visual Studio that includes
# CMake 3.14 or later. You should not increase this version, as doing so will
# cause the plugin to fail to compile for some customers of the plugin.
cmake_minimum_required(VERSION 3.14)

# Project-level configuration.
set(PROJECT_NAME "rust_lib_gitdeck")
project(${PROJECT_NAME} LANGUAGES CXX)

include("../cargokit/cmake/cargokit.cmake")
# NOTE: on Windows the plugin_symlinks entries are copies, not symlinks, so the
# relative path to the rust crate is deeper than on linux/macOS (FRB template).
apply_cargokit(${PROJECT_NAME} ../../../../../../rust rust_lib_gitdeck "")

# List of absolute paths to libraries that should be bundled with the plugin.
# This list could contain prebuilt libraries, or libraries created by an
# external build triggered from this build file.
set(rust_lib_gitdeck_bundled_libraries
  "${${PROJECT_NAME}_cargokit_lib}"
  PARENT_SCOPE
)
