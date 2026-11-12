#!/usr/bin/env bash
# Build the carrier APK.
#
# This repository compiles no native code. The engine libraries are pulled in
# by scripts/fetch-engine-libs.sh from the engine repository's "Android build"
# workflow, which is the whole point of the split: the engine produces
# aarch64 modules, this produces the app that loads them.
#
# Previously this script built jni/src/tierhook and every srcsdk module at
# APP_API_LEVEL=19 into libs/armeabi-v7a -- 32-bit, from the old SDK tree, for a
# different engine. That is gone; L4D1 is aarch64 and the engine owns it.

set -uo pipefail

cd "$(dirname "$0")/.."

: "${DEPLOY_BRANCH:=srceng-l4d1}"
: "${COMMIT:=$(git rev-parse HEAD)}"
: "${JAVA_HOME:=/usr/lib/jvm/java-8-openjdk-amd64}"
: "${ANDROID_HOME:=android-sdk}"
export JAVA_HOME ANDROID_HOME

info() { echo "$*"; }
warn() { echo "::warning::$*"; }

generate_resources() {
	local res=res/values/build_info.xml
	mkdir -p "$(dirname "$res")"
	{
		echo '<?xml version="1.0" encoding="utf-8"?>'
		echo '<resources>'
		echo "<string name=\"last_commit\">${COMMIT}</string>"
		echo "<string name=\"deploy_branch\">${DEPLOY_BRANCH}</string>"
		echo '</resources>'
	} >"$res"
	info "build_info.xml: commit ${COMMIT}, branch ${DEPLOY_BRANCH}"
}

# --- engine libraries ------------------------------------------------------
if [ "${SKIP_LIBRARIES:-0}" = "1" ]; then
	warn "SKIP_LIBRARIES=1 - building the APK with no engine libraries"
else
	# Degrade to an APK with no engine libraries rather than failing the whole
	# build: a green run that produces an installable shell is still worth
	# having, and the fetch script annotates whatever went wrong.
	scripts/fetch-engine-libs.sh || warn "continuing without engine libraries"
fi

generate_resources

# ant debug signs with ~/.android/debug.keystore. The project keeps one
# committed on purpose so builds update in place on the device.
mkdir -p "$HOME/.android"
[ -f debug.keystore ] && cp -f debug.keystore "$HOME/.android/debug.keystore"

info "JAVA_HOME=${JAVA_HOME}"
info "ANDROID_HOME=${ANDROID_HOME}"
info "modules staged:"
ls -l libs/*/ 2>/dev/null || warn "no native libraries staged"

ant debug || exit 1

echo -n "$COMMIT" >version

APK=bin/srceng-debug.apk
if [ ! -f "$APK" ]; then
	warn "ant finished but ${APK} does not exist"
	exit 1
fi

info "Built ${APK} ($(wc -c <"$APK" | tr -d ' ') bytes)"
