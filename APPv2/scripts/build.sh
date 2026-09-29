#!/usr/bin/env bash
# Keep optional SDK downloads, build caches, and development signing in APPv2.
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
mkdir -p "$project_dir/.tools"

if [[ -z "${JAVA_HOME:-}" ]]; then
    for candidate in "$project_dir"/.tools/jdk-17*/Contents/Home "$project_dir"/.tools/jdk-17*; do
        if [[ -x "$candidate/bin/java" ]]; then
            export JAVA_HOME="$candidate"
            break
        fi
    done
fi
if [[ -z "${JAVA_HOME:-}" || ! -x "$JAVA_HOME/bin/java" ]]; then
    echo 'Set JAVA_HOME to a JDK 17 installation, or place JDK 17 under APPv2/.tools.' >&2
    exit 1
fi
export ANDROID_HOME="${ANDROID_HOME:-$project_dir/.tools/android-sdk}"
export ANDROID_USER_HOME="$project_dir/.tools/android-user"
export GRADLE_USER_HOME="$project_dir/.tools/gradle-user-home"
export PATH="$JAVA_HOME/bin:$ANDROID_HOME/platform-tools:$PATH"

if [[ ! -f "$project_dir/.tools/debug.keystore" ]]; then
    "$JAVA_HOME/bin/keytool" -genkeypair -keystore "$project_dir/.tools/debug.keystore" \
        -storepass android -keypass android -alias androiddebugkey \
        -dname 'CN=Android Debug,O=Android,C=US' -keyalg RSA -keysize 2048 -validity 10000
fi

if [[ $# -eq 0 ]]; then
    set -- :core:test :wear:assembleDebug :phone:assembleDebug
fi
exec "$project_dir/gradlew" "$@"
