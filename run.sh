#!/bin/zsh

JUST_BUILD=false
if [[ "$1" == "build" ]]; then
    JUST_BUILD=true
fi

echo "Building autocorrect-swift..."
mkdir -p build
cargo build -p autocorrect-swift --release --target aarch64-apple-darwin --manifest-path=asian-autocorrect/Cargo.toml
cp ./asian-autocorrect/target/aarch64-apple-darwin/release/libautocorrect_swift.dylib ./build/libautocorrect_swift.dylib
install_name_tool -id "@rpath/libautocorrect_swift.dylib" ./build/libautocorrect_swift.dylib
codesign --force --sign - ./build/libautocorrect_swift.dylib
if [[ $? -ne 0 ]]; then
    echo "Cargo build failed!"
    exit 1
fi

echo "Building text-processing-rs..."
cargo build --release --features ffi --target aarch64-apple-darwin --manifest-path=text-processing-rs/Cargo.toml
cp ./text-processing-rs/target/aarch64-apple-darwin/release/libtext_processing_rs.dylib ./build/libtext_processing_rs.dylib
install_name_tool -id "@rpath/libtext_processing_rs.dylib" ./build/libtext_processing_rs.dylib
codesign --force --sign - ./build/libtext_processing_rs.dylib
if [[ $? -ne 0 ]]; then
    echo "text-processing-rs build failed!"
    exit 1
fi

echo "Copying libomp.dylib..."
rm -f ./build/libomp.dylib
cp /opt/homebrew/opt/libomp/lib/libomp.dylib ./build/libomp.dylib
install_name_tool -id "@rpath/libomp.dylib" ./build/libomp.dylib
codesign --force --sign - ./build/libomp.dylib

# Build WeTextProcessing ITN processor
if [ ! -f ./build/processor_main ] || [ ! -f ./build/zh_itn_tagger.fst ] || [ ! -f ./build/zh_itn_verbalizer.fst ]; then
    echo "Building WeTextProcessing ITN processor..."
    cmake -B WeTextProcessing/build -S WeTextProcessing/runtime -DCMAKE_BUILD_TYPE=Release -DCMAKE_POLICY_VERSION_MINIMUM=3.5 2>&1 | tail -3
    # Apply OpenFst patch if needed (idempotent via -N, glob handles compiler-specific dir name)
    patch -p1 -N -d WeTextProcessing/runtime/fc_base-*/openfst-src < patches/WeTextProcessing/001-fix-openfst-bi-table-copy-ctor.patch 2>/dev/null || true
    cmake --build WeTextProcessing/build -j8 2>&1 | tail -5
    if [ -f WeTextProcessing/build/bin/processor_main ]; then
        cp WeTextProcessing/build/bin/processor_main ./build/processor_main
        codesign --force --sign - ./build/processor_main
        cp Resources/ITN/zh_itn_tagger.fst ./build/zh_itn_tagger.fst
        cp Resources/ITN/zh_itn_verbalizer.fst ./build/zh_itn_verbalizer.fst
        echo "WeTextProcessing build successful!"
    else
        echo "Warning: WeTextProcessing build failed, ITN will be unavailable"
    fi
else
    echo "WeTextProcessing already built, skipping..."
fi

# Resolve SPM packages and apply patches before building
"$(dirname "$0")/Scripts/resolve_and_patch.sh"

# Pick code-signing identity:
#   1. If DEV_SIGN_IDENTITY env var is set, use it (explicit override).
#   2. Otherwise, if a "OpenSuperMLX Dev" code-signing identity is in the user's
#      keychain, use it. This gives the resulting .app a stable codesign identity
#      across rebuilds, so macOS TCC keeps Accessibility / Microphone / Screen
#      Recording permissions instead of re-prompting on every build.
#   3. Otherwise (CI, fresh clones), fall back to ad-hoc signing — the historical
#      default. Permissions will be re-requested on every rebuild.
#
# When using a real signing identity, we also disable Hardened Runtime and the
# debug-dylib split so library validation doesn't reject our self-signed dylibs
# (libomp, libautocorrect_swift, libtext_processing_rs).
DEV_SIGN_IDENTITY="${DEV_SIGN_IDENTITY:-OpenSuperMLX Dev}"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$DEV_SIGN_IDENTITY\""; then
    echo "Code signing: using \"$DEV_SIGN_IDENTITY\" (TCC permissions persist across rebuilds)"
    SIGN_ARGS=(
        CODE_SIGN_IDENTITY="$DEV_SIGN_IDENTITY"
        CODE_SIGN_STYLE=Manual
        CODE_SIGNING_REQUIRED=YES
        CODE_SIGNING_ALLOWED=YES
        ENABLE_DEBUG_DYLIB=NO
        ENABLE_HARDENED_RUNTIME=NO
    )
else
    echo "Code signing: ad-hoc (install \"$DEV_SIGN_IDENTITY\" cert in Keychain to persist TCC permissions)"
    SIGN_ARGS=(
        CODE_SIGNING_ALLOWED=NO
        CODE_SIGN_IDENTITY=""
        CODE_SIGNING_REQUIRED=NO
        OTHER_CODE_SIGN_FLAGS="--entitlements OpenSuperMLX/OpenSuperMLX.entitlements"
    )
fi

# Build the app
echo "Building OpenSuperMLX..."
BUILD_OUTPUT=$(xcodebuild -scheme OpenSuperMLX -configuration Debug -jobs 8 -derivedDataPath build -quiet -destination 'platform=macOS,arch=arm64' -skipPackagePluginValidation -skipMacroValidation -UseModernBuildSystem=YES -clonedSourcePackagesDirPath SourcePackages -skipUnavailableActions "${SIGN_ARGS[@]}" build 2>&1)

# sudo gem install xcpretty
if command -v xcpretty &> /dev/null
then
    echo "$BUILD_OUTPUT" | xcpretty --simple --color
else
    echo "$BUILD_OUTPUT"
fi

# Check if build output contains BUILD FAILED or if the command failed
if [[ $? -eq 0 ]] && [[ ! "$BUILD_OUTPUT" =~ "BUILD FAILED" ]]; then
    echo "Building successful!"
    if $JUST_BUILD; then
        exit 0
    fi
    echo "Starting the app..."
    # Remove quarantine attribute if exists
    xattr -d com.apple.quarantine ./Build/Build/Products/Debug/OpenSuperMLX.app 2>/dev/null || true
    # Run the app and show logs
    ./Build/Build/Products/Debug/OpenSuperMLX.app/Contents/MacOS/OpenSuperMLX
else
    echo "Build failed!"
    exit 1
fi 