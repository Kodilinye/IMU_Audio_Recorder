#!/usr/bin/env bash
# Optional reproducible toolchain bootstrap for this Apple Silicon development host.
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ]]; then
    echo 'This bootstrap is for Apple Silicon macOS. On other hosts install JDK 17 and Android SDK 36, then run scripts/build.sh.' >&2
    exit 1
fi
mkdir -p .tools/downloads .tools/android-sdk/cmdline-tools
download() {
    local url="$1" destination="$2" checksum="$3"
    if [[ ! -f "$destination" ]]; then curl -fL --retry 3 "$url" -o "$destination"; fi
    printf '%s  %s\n' "$checksum" "$destination" | shasum -a 256 -c -
}
if [[ ! -x .tools/jdk-17.0.20.1+1/Contents/Home/bin/java ]]; then
    download 'https://github.com/adoptium/temurin17-binaries/releases/download/jdk-17.0.20.1%2B1/OpenJDK17U-jdk_aarch64_mac_hotspot_17.0.20.1_1.tar.gz' \
        .tools/downloads/jdk17.tar.gz 196d13ba5f10414bef7f6a05a9b3f00edacb18ebacef2b99485db9e2ee18f0e8
    tar -xzf .tools/downloads/jdk17.tar.gz -C .tools
fi
if [[ ! -x .tools/android-sdk/cmdline-tools/latest/bin/sdkmanager ]]; then
    download 'https://dl.google.com/android/repository/commandlinetools-mac_arm64-15859902_latest.zip' \
        .tools/downloads/android-commandline.zip 835b62a26162b229b441d1f6d4680383815a270809eb33522c0d480fa5002c4e
    unzip -q .tools/downloads/android-commandline.zip -d .tools/android-sdk/cmdline-tools
    mv .tools/android-sdk/cmdline-tools/cmdline-tools .tools/android-sdk/cmdline-tools/latest
fi
export JAVA_HOME="$project_dir/.tools/jdk-17.0.20.1+1/Contents/Home"
export ANDROID_HOME="$project_dir/.tools/android-sdk"
export ANDROID_USER_HOME="$project_dir/.tools/android-user"
"$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager" --sdk_root="$ANDROID_HOME" \
    'platforms;android-36' 'build-tools;35.0.0' 'platform-tools'
echo 'Toolchain ready. Run scripts/build.sh to test and build both apps.'
