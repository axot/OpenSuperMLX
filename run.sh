#!/bin/zsh

JUST_BUILD=false
if [[ "$1" == "build" ]]; then
    JUST_BUILD=true
fi

EXPLICIT_SIGN_IDENTITY=false
if [[ -n "${DEV_SIGN_IDENTITY:-}" ]]; then
    EXPLICIT_SIGN_IDENTITY=true
    REQUESTED_SIGN_IDENTITY="$DEV_SIGN_IDENTITY"
fi

VALID_CODE_SIGNING_IDENTITIES=$(security find-identity -v -p codesigning 2>/dev/null)
IDENTITY_PATTERN='^[[:space:]]*[0-9]+\)[[:space:]]+([[:xdigit:]]{40})[[:space:]]+"([^"]+)"'
typeset -a INSTALLED_IDENTITY_HASHES INSTALLED_IDENTITY_NAMES DEVELOPER_ID_HASHES
HAS_OPENSUPERMLX_DEV=false

while IFS= read -r identity_line; do
    if [[ "$identity_line" =~ $IDENTITY_PATTERN ]]; then
        identity_hash="${match[1]}"
        identity_name="${match[2]}"
        INSTALLED_IDENTITY_HASHES+=("$identity_hash")
        INSTALLED_IDENTITY_NAMES+=("$identity_name")
        if [[ "$identity_name" == "Developer ID Application:"* ]]; then
            DEVELOPER_ID_HASHES+=("$identity_hash")
        fi
        if [[ "$identity_name" == "OpenSuperMLX Dev" ]]; then
            HAS_OPENSUPERMLX_DEV=true
        fi
    fi
done <<< "$VALID_CODE_SIGNING_IDENTITIES"

SIGN_IDENTITY="-"
if $EXPLICIT_SIGN_IDENTITY; then
    IDENTITY_MATCHED=false
    for identity_hash in "${INSTALLED_IDENTITY_HASHES[@]}"; do
        if [[ "${(U)REQUESTED_SIGN_IDENTITY}" == "${(U)identity_hash}" ]]; then
            SIGN_IDENTITY="$identity_hash"
            IDENTITY_MATCHED=true
            break
        fi
    done
    if ! $IDENTITY_MATCHED; then
        for identity_name in "${INSTALLED_IDENTITY_NAMES[@]}"; do
            if [[ "$REQUESTED_SIGN_IDENTITY" == "$identity_name" ]]; then
                SIGN_IDENTITY="$identity_name"
                IDENTITY_MATCHED=true
                break
            fi
        done
    fi
    if $IDENTITY_MATCHED; then
        echo "Code signing: using explicit DEV_SIGN_IDENTITY \"$SIGN_IDENTITY\""
    else
        echo "Warning: DEV_SIGN_IDENTITY \"$REQUESTED_SIGN_IDENTITY\" is not a valid installed code-signing identity; using ad-hoc signing."
    fi
elif (( ${#DEVELOPER_ID_HASHES[@]} == 1 )); then
    SIGN_IDENTITY="${DEVELOPER_ID_HASHES[1]}"
    echo "Code signing: using the single installed Developer ID Application identity ($SIGN_IDENTITY)"
else
    if (( ${#DEVELOPER_ID_HASHES[@]} > 1 )); then
        echo "Code signing: found ${#DEVELOPER_ID_HASHES[@]} Developer ID Application identities; refusing to choose one arbitrarily."
    fi
    if $HAS_OPENSUPERMLX_DEV; then
        SIGN_IDENTITY="OpenSuperMLX Dev"
        echo "Code signing: using exact fallback identity \"$SIGN_IDENTITY\""
    else
        echo "Code signing: using ad-hoc identity '-'"
    fi
fi

typeset -a CODESIGN_ARGS XCODE_SIGN_ARGS
if [[ "$SIGN_IDENTITY" == "-" ]]; then
    CODESIGN_ARGS=(--force --sign -)
else
    CODESIGN_ARGS=(--force --sign "$SIGN_IDENTITY" --timestamp=none)
fi

XCODE_SIGN_ARGS=(
    CODE_SIGN_IDENTITY="$SIGN_IDENTITY"
    CODE_SIGN_STYLE=Manual
    CODE_SIGNING_REQUIRED=YES
    CODE_SIGNING_ALLOWED=YES
    ENABLE_DEBUG_DYLIB=NO
    ENABLE_HARDENED_RUNTIME=NO
)
if [[ "$SIGN_IDENTITY" != "-" ]]; then
    XCODE_SIGN_ARGS+=(OTHER_CODE_SIGN_FLAGS="--timestamp=none")
fi

echo "Building autocorrect-swift..."
mkdir -p build
cargo build -p autocorrect-swift --release --target aarch64-apple-darwin --manifest-path=asian-autocorrect/Cargo.toml
cp ./asian-autocorrect/target/aarch64-apple-darwin/release/libautocorrect_swift.dylib ./build/libautocorrect_swift.dylib
install_name_tool -id "@rpath/libautocorrect_swift.dylib" ./build/libautocorrect_swift.dylib
codesign "${CODESIGN_ARGS[@]}" ./build/libautocorrect_swift.dylib
if [[ $? -ne 0 ]]; then
    echo "Cargo build failed!"
    exit 1
fi

echo "Building text-processing-rs..."
cargo build --release --features ffi --target aarch64-apple-darwin --manifest-path=text-processing-rs/Cargo.toml
cp ./text-processing-rs/target/aarch64-apple-darwin/release/libtext_processing_rs.dylib ./build/libtext_processing_rs.dylib
install_name_tool -id "@rpath/libtext_processing_rs.dylib" ./build/libtext_processing_rs.dylib
codesign "${CODESIGN_ARGS[@]}" ./build/libtext_processing_rs.dylib
if [[ $? -ne 0 ]]; then
    echo "text-processing-rs build failed!"
    exit 1
fi

echo "Copying libomp.dylib..."
rm -f ./build/libomp.dylib
cp /opt/homebrew/opt/libomp/lib/libomp.dylib ./build/libomp.dylib
install_name_tool -id "@rpath/libomp.dylib" ./build/libomp.dylib
codesign "${CODESIGN_ARGS[@]}" ./build/libomp.dylib

# Build WeTextProcessing ITN processor
if [ ! -f ./build/processor_main ] || [ ! -f ./build/zh_itn_tagger.fst ] || [ ! -f ./build/zh_itn_verbalizer.fst ]; then
    echo "Building WeTextProcessing ITN processor..."
    cmake -B WeTextProcessing/build -S WeTextProcessing/runtime -DCMAKE_BUILD_TYPE=Release -DCMAKE_POLICY_VERSION_MINIMUM=3.5 2>&1 | tail -3
    # Apply OpenFst patch if needed (idempotent via -N, glob handles compiler-specific dir name)
    patch -p1 -N -d WeTextProcessing/runtime/fc_base-*/openfst-src < patches/WeTextProcessing/001-fix-openfst-bi-table-copy-ctor.patch 2>/dev/null || true
    cmake --build WeTextProcessing/build -j8 2>&1 | tail -5
    if [ -f WeTextProcessing/build/bin/processor_main ]; then
        cp WeTextProcessing/build/bin/processor_main ./build/processor_main
        cp Resources/ITN/zh_itn_tagger.fst ./build/zh_itn_tagger.fst
        cp Resources/ITN/zh_itn_verbalizer.fst ./build/zh_itn_verbalizer.fst
        echo "WeTextProcessing build successful!"
    else
        echo "Warning: WeTextProcessing build failed, ITN will be unavailable"
    fi
else
    echo "WeTextProcessing already built, skipping..."
fi

if [ -f ./build/processor_main ]; then
    codesign "${CODESIGN_ARGS[@]}" ./build/processor_main
fi

# Resolve SPM packages and apply patches before building
"$(dirname "$0")/Scripts/resolve_and_patch.sh"

# Build the app
echo "Building OpenSuperMLX..."
BUILD_OUTPUT=$(xcodebuild -scheme OpenSuperMLX -configuration Debug -jobs 8 -derivedDataPath build -quiet -destination 'platform=macOS,arch=arm64' -skipPackagePluginValidation -skipMacroValidation -UseModernBuildSystem=YES -clonedSourcePackagesDirPath SourcePackages -skipUnavailableActions "${XCODE_SIGN_ARGS[@]}" build 2>&1)
BUILD_STATUS=$?

# sudo gem install xcpretty
if command -v xcpretty &> /dev/null
then
    echo "$BUILD_OUTPUT" | xcpretty --simple --color
else
    echo "$BUILD_OUTPUT"
fi

if [[ $BUILD_STATUS -eq 0 ]]; then
    echo "Building successful!"
    if $JUST_BUILD; then
        exit 0
    fi
    echo "Starting the app..."
    ./build/Build/Products/Debug/OpenSuperMLX.app/Contents/MacOS/OpenSuperMLX
else
    echo "Build failed!"
    exit 1
fi
