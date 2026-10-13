#
# macOS podspec for the Rust FFI plugin. Mirrors ios/rust_lib_gitdeck.podspec:
# cargokit builds the static library via build_pod.sh and the pod force-loads
# it into the app binary so the Dart @Native symbols resolve.
#
Pod::Spec.new do |s|
  s.name             = 'rust_lib_gitdeck'
  s.version          = '0.0.1'
  s.summary          = 'AiwliGit native Git engine built with Rust and libgit2.'
  s.description      = <<-DESC
AiwliGit native Git engine built with Rust and libgit2.
                       DESC
  s.homepage         = 'https://github.com/aiwli/aiwli_git'
  s.license          = { :file => '../../LICENSE' }
  s.author           = { 'AiwliGit contributors' => 'https://github.com/aiwli/aiwli_git' }

  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'FlutterMacOS'
  s.platform = :osx, '12.0'
  s.swift_version = '5.0'

  s.script_phase = {
    :name => 'Build Rust library',
    # First argument is relative path to the `rust` folder, second is name of rust library
    :script => 'sh "$PODS_TARGET_SRCROOT/../cargokit/build_pod.sh" ../../rust rust_lib_gitdeck',
    :execution_position => :before_compile,
    :input_files => ['${BUILT_PRODUCTS_DIR}/cargokit_phony'],
    # Let XCode know that the static library referenced in -force_load below is
    # created by this build step.
    :output_files => ["${BUILT_PRODUCTS_DIR}/librust_lib_gitdeck.a"],
  }
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'OTHER_LDFLAGS' => '-force_load ${BUILT_PRODUCTS_DIR}/librust_lib_gitdeck.a -lz -liconv',
  }
end
