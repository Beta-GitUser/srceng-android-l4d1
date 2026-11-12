#!/usr/bin/env bash
# Every DT_NEEDED of every module in the APK has to resolve at runtime: either
# it ships in the APK's lib/<abi>/, or the platform provides it. One that does
# neither is a dlopen failure on the device, reported as a black screen or a
# "library not found" toast -- and with no adb there is no way to see which.
# So read the ELF dynamic sections here, where it is cheap.
#
# This is what a missing libSDL2.so looks like: the Java side asks for a library
# the APK does not contain, or a module needs one nobody shipped.

set -uo pipefail

APK="${1:-bin/srceng-debug.apk}"

warn()   { echo "::warning::$*"; }
notice() { echo "::notice::$*"; }
info()   { echo "$*"; }

if [ ! -f "$APK" ]; then
	warn "${APK} does not exist; skipping the dependency check"
	exit 0
fi

# Anything the platform itself supplies. Keep it to things that really are on
# the device, or this check stops being useful.
SYSTEM_LIBS="
libc.so libm.so libdl.so liblog.so libz.so libstdc++.so
libEGL.so libGLESv1_CM.so libGLESv2.so libGLESv3.so
libOpenSLES.so libOpenMAXAL.so libandroid.so libjnigraphics.so
libnativewindow.so libvulkan.so libaaudio.so libamidi.so
libcamera2ndk.so libmediandk.so libneuralnetworks.so libsync.so
libbinder_ndk.so libcutils.so libutils.so libui.so libgui.so
libhwui.so libskia.so libft2.so libharfbuzz_ng.so libpng.so
libcrypto.so libssl.so libcompiler_rt.so libm_hard.so
"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

unzip -q -o "$APK" 'lib/*' -d "$TMP" 2>/dev/null || true

modules=()
while IFS= read -r so; do modules+=("$so"); done < <(find "$TMP/lib" -type f -name '*.so' 2>/dev/null | sort)

if [ "${#modules[@]}" -eq 0 ]; then
	warn "the APK contains no native libraries at all"
	exit 0
fi

# Names the APK itself provides.
provided=()
while IFS= read -r n; do provided+=("$n"); done < <(printf '%s\n' "${modules[@]}" | xargs -n1 basename | sort -u)

info "modules in the APK: ${provided[*]}"

have_readelf=0
command -v readelf >/dev/null 2>&1 && have_readelf=1

read_needed() {
	local so="$1"
	if [ "$have_readelf" = "1" ]; then
		readelf -d "$so" 2>/dev/null
	else
		objdump -p "$so" 2>/dev/null
	fi | sed -n 's/.*NEEDED.*\[\([^]]*\)\].*/\1/p'
}

unresolved=0
for so in "${modules[@]}"; do
	name="$(basename "$so")"
	abi="$(basename "$(dirname "$so")")"

	needed=()
	while IFS= read -r n; do needed+=("$n"); done < <(read_needed "$so")
	[ "${#needed[@]}" -eq 0 ] && continue

	missing=()
	for n in "${needed[@]}"; do
		[ -z "$n" ] && continue
		case " ${provided[*]} " in
			*" ${n} "*) continue ;;
		esac
		case "$SYSTEM_LIBS" in
			*" ${n} "*) continue ;;
		esac
		missing+=("$n")
	done

	if [ "${#missing[@]}" -gt 0 ]; then
		for m in "${missing[@]}"; do
			warn "${abi}/${name} needs ${m}, which is not in the APK and is not a platform library - dlopen will fail"
		done
		unresolved=$((unresolved + 1))
	else
		info "ok   ${abi}/${name} (${#needed[@]} needed, all resolvable)"
	fi
done

if [ "$unresolved" -gt 0 ]; then
	warn "${unresolved} module(s) have unresolved shared-library dependencies"
else
	notice "every DT_NEEDED of every module is provided by the APK or by the platform"
fi

exit 0
