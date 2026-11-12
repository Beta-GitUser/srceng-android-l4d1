#!/usr/bin/env bash
# Make an Android SDK that the legacy Ant build can actually use.
#
# build.xml imports ${sdk.dir}/tools/ant/build.xml. That file belongs to the
# pre-2015 SDK Tools layout (last shipped in SDK Tools r25.2.5) and is not part
# of the modern "commandline-tools" package, nor of the SDK preinstalled on
# GitHub runners. So "an Android SDK" is not enough: it has to be one with the
# ant rules still in it.
#
# The build also needs dx, not d8 -- the ant rules invoke
# ${build.tools.dir}/lib/dx.jar, and dx was removed from build-tools after
# 30.0.3. That caps the usable build-tools at 30.0.3.
#
# Strategy, cheapest first:
#   1. $ANDROID_HOME already has the ant rules  -> use it
#   2. clone the pinned SDK this project has used historically
#   3. build one up from the runner's own SDK + the legacy tools archive
#
# Writes ANDROID_HOME/ANDROID_SDK_ROOT to $GITHUB_ENV when running in Actions.

set -uo pipefail

SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/android-sdk}}"
SDK_GIT="${SDK_GIT:-https://gitlab.com/LostGamer/android-sdk}"
LEGACY_TOOLS_URL="${LEGACY_TOOLS_URL:-https://dl.google.com/android/repository/tools_r25.2.5-linux.zip}"
WANT_PLATFORM="${WANT_PLATFORM:-android-29}"
WANT_BUILD_TOOLS="${WANT_BUILD_TOOLS:-30.0.3}"

info() { echo "$*"; }
warn() { echo "::warning::$*"; }
die()  { echo "::error::$*"; exit 1; }

export_env() {
	# In Actions every step is a fresh shell, so the value has to be persisted.
	[ -n "${GITHUB_ENV:-}" ] && echo "ANDROID_HOME=$SDK" >>"$GITHUB_ENV"
	[ -n "${GITHUB_ENV:-}" ] && echo "ANDROID_SDK_ROOT=$SDK" >>"$GITHUB_ENV"
	[ -n "${GITHUB_PATH:-}" ] && echo "$SDK/platform-tools" >>"$GITHUB_PATH"
}

complete_enough() {
	[ -f "$SDK/tools/ant/build.xml" ] || return 1
	[ -d "$SDK/platforms/${WANT_PLATFORM}" ] || return 1
	[ -d "$SDK/build-tools/${WANT_BUILD_TOOLS}" ] || return 1
	return 0
}

mkdir -p "$SDK"

if complete_enough; then
	info "SDK at ${SDK} already has ant rules, ${WANT_PLATFORM} and build-tools ${WANT_BUILD_TOOLS}"
	die_if_nothing_else
fi

# --- 2. the pinned SDK -----------------------------------------------------
if [ ! -d "$SDK/.git" ] && [ ! -f "$SDK/tools/ant/build.xml" ]; then
	info "Cloning pinned SDK from ${SDK_GIT}"
	rm -rf "${SDK}.tmp"
	# Not piped to tail: that would make the exit status tail's, and a failed
	# clone would look like a success with an empty SDK.
	if git clone --depth 1 "$SDK_GIT" "${SDK}.tmp" >"${TMPDIR:-/tmp}/sdk-clone.log" 2>&1; then
		rm -rf "$SDK"
		mv "${SDK}.tmp" "$SDK"
	else
		tail -n 5 "${TMPDIR:-/tmp}/sdk-clone.log" || true
		rm -rf "${SDK}.tmp"
		warn "clone failed; falling back to building an SDK from the runner image"
	fi
fi

# --- 3. fill the gaps ------------------------------------------------------
# platform + build-tools from the runner's own sdkmanager
if command -v sdkmanager >/dev/null 2>&1; then
	yes 2>/dev/null | sdkmanager --sdk_root="$SDK" --licenses >/dev/null 2>&1 || true
	for pkg in "platforms;${WANT_PLATFORM}" "build-tools;${WANT_BUILD_TOOLS}"; do
		if [ ! -d "$SDK/$(echo "$pkg" | tr ';' '/')" ]; then
			info "Installing ${pkg}"
			yes 2>/dev/null | sdkmanager --sdk_root="$SDK" "$pkg" 2>&1 | tail -5 || true
		fi
	done
fi

# legacy tools/ant/build.xml
if [ ! -f "$SDK/tools/ant/build.xml" ]; then
	info "Fetching legacy SDK Tools (r25.2.5) for the ant rules"
	tmp="$(mktemp -d)"
	if curl -fsSL -o "${tmp}/tools.zip" "$LEGACY_TOOLS_URL"; then
		unzip -q -o "${tmp}/tools.zip" -d "${tmp}/unpacked" || true
		if [ -f "${tmp}/unpacked/tools/ant/build.xml" ]; then
			mkdir -p "$SDK/tools"
			cp -r "${tmp}/unpacked/tools/." "$SDK/tools/"
			chmod +x "$SDK/tools/"* 2>/dev/null || true
		fi
	fi
	rm -rf "$tmp"
fi

# --- report ----------------------------------------------------------------
info "--- $SDK ---"
info "ant rules:    $([ -f "$SDK/tools/ant/build.xml" ] && echo present || echo MISSING)"
info "platforms:    $(ls -1 "$SDK/platforms" 2>/dev/null | tr '\n' ' ')"
info "build-tools:  $(ls -1 "$SDK/build-tools" 2>/dev/null | tr '\n' ' ')"
if [ -d "$SDK/build-tools/${WANT_BUILD_TOOLS}" ]; then
	info "dx.jar:       $([ -f "$SDK/build-tools/${WANT_BUILD_TOOLS}/lib/dx.jar" ] && echo present || echo MISSING)"
fi

if [ ! -f "$SDK/tools/ant/build.xml" ]; then
	die "no Android SDK with tools/ant/build.xml. Ant cannot build this project without one; see scripts/setup-android-sdk.sh"
fi
if [ ! -d "$SDK/platforms/${WANT_PLATFORM}" ]; then
	warn "platform ${WANT_PLATFORM} is not installed - ant will fail unless project.properties targets an installed platform"
fi
if [ ! -d "$SDK/build-tools/${WANT_BUILD_TOOLS}" ]; then
	local_bt="$(ls -1 "$SDK/build-tools" 2>/dev/null | sort -V | tail -1)"
	if [ -n "$local_bt" ]; then
		warn "build-tools ${WANT_BUILD_TOOLS} is not installed; the newest available is ${local_bt}"
		WANT_BUILD_TOOLS="$local_bt"
	else
		die "no build-tools installed - dx is required"
	fi
fi

echo "ANDROID_BUILD_TOOLS=${WANT_BUILD_TOOLS}" >>"${GITHUB_ENV:-/dev/null}"
export_env
