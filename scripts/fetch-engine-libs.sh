#!/usr/bin/env bash
# Stage the engine's aarch64 libraries where the APK build will find them.
#
# The carrier does not compile native code. It consumes the
# "android-aarch64-libraries" artifact published by the "Android build"
# workflow of the engine repository, and drops the modules into libs/arm64-v8a/
# so ant packages them as lib/arm64-v8a/ -- the directory APP_LIB_PATH points at
# on the device, and the only directory Sys_LoadModule's Android branch searches.
#
# Both repositories are public, so this needs no credentials: GitHub answers an
# anonymous artifact request with a redirect to its storage just the same. If
# the engine repository ever goes private, set GITHUB_TOKEN to a token that can
# read it.
#
# Module names are case-sensitive: waf writes libGameUI.so (gameui/wscript uses
# target 'GameUI'), and foundLibraryWithPrefix in tier1/interface.cpp looks for
# exactly "lib" + name + ".so". Getting that wrong is a silent no-module.
#
# Overrides:
#   ENGINE_REPO     owner/repo         (default Beta-GitUser/source-engine-l4d1)
#   ENGINE_BRANCH   branch to trust    (default the L4D1 work branch)
#   ENGINE_RUN_ID   pin a specific run (default: latest successful run)
#   ARTIFACT_NAME   artifact to pull   (default android-aarch64-libraries)
#   ABI_DIR         staging directory  (default libs/arm64-v8a)
#   GITHUB_TOKEN    optional; lifts the API rate limit from 60/h to 5000/h

set -uo pipefail

ENGINE_REPO="${ENGINE_REPO:-Beta-GitUser/source-engine-l4d1}"
ENGINE_BRANCH="${ENGINE_BRANCH:-arena/410ac3e6-source-engine-l4d1}"
ENGINE_WORKFLOW_FILE="${ENGINE_WORKFLOW_FILE:-android.yml}"
ARTIFACT_NAME="${ARTIFACT_NAME:-android-aarch64-libraries}"
RUN_ID="${ENGINE_RUN_ID:-}"
ABI_DIR="${ABI_DIR:-libs/arm64-v8a}"

# Prebuilts the modules link against that the engine's artifact does not
# carry. This is the repository the engine mounts at lib/ and that its
# wscript installs SDL2 from, so these are the very binaries the modules were
# linked against rather than a rebuild that could drift.
EXTRA_LIBS_REPO="${EXTRA_LIBS_REPO:-nillerusr/source-engine-libs}"
EXTRA_LIBS_PATH="${EXTRA_LIBS_PATH:-android/aarch64}"
EXTRA_LIBS_REF="${EXTRA_LIBS_REF:-master}"

EXPECT_CLASS="ELF64"
EXPECT_MACHINE="183"   # EM_AARCH64

# libclient/server/launcher are the engine and the game modules: without them
# nothing runs at all, so they are required.
#
# libGameUI.so is the VGUI main menu. It is a separate waf target
# (gameui/wscript, target 'GameUI'), the engine's own "Collect libraries" step
# reports it as absent on the L4D1 branch, and the Android entry point is
# launcher/android/main.cpp -- which may go straight to a map and never load
# the menu. Whether it is needed is an engine-side question, so the carrier
# stages it when it exists and only warns when it does not.
REQUIRED_MODULES=(libclient.so libserver.so liblauncher.so)
OPTIONAL_MODULES=(libGameUI.so)
MODULES=("${REQUIRED_MODULES[@]}" "${OPTIONAL_MODULES[@]}")

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

warn() { echo "::warning::$*"; }
notice() { echo "::notice::$*"; }
info() { echo "$*"; }
fail() { echo "::error::$*"; }

# The best token available, in the order that matters. Actions scopes
# GITHUB_TOKEN to this repository, so it is last: it keeps the API calls
# working against api.github.com's anonymous rate limit even when no token
# that can reach the engine repository is configured.
best_token() {
	local var tok
	for var in ENGINE_ARTIFACT_TOKEN GH_TOKEN API_GITHUB_TOKEN GITHUB_TOKEN; do
		eval "tok=\${${var}:-}"
		if [ -n "$tok" ]; then
			printf '%s' "$tok"
			return 0
		fi
	done
	return 0
}

# Quiet variant of curl for API calls. -f makes HTTP errors visible to the
# caller instead of silently writing an error document to stdout.
api_json() {
	local path="$1"; shift
	local tok; tok="$(best_token)"
	local -a hdr=(-fsSL -H "Accept: application/vnd.github+json")
	if [ -n "$tok" ]; then
		hdr+=(-H "Authorization: Bearer ${tok}")
	fi
	curl "${hdr[@]}" "$@" "https://api.github.com/${path}"
}

elf_info() {
	python3 - "$1" <<'PY'
import struct, sys
try:
    with open(sys.argv[1], "rb") as fh:
        head = fh.read(20)
except OSError:
    print("unreadable 0")
    sys.exit(0)
if len(head) < 20 or head[:4] != b"\x7fELF":
    print("not-an-ELF 0")
    sys.exit(0)
print("%s %d" % ("ELF64" if head[4] == 2 else "ELF32", struct.unpack_from("<H", head, 18)[0]))
PY
}

# --- resolve the run -------------------------------------------------------
if [ -z "$RUN_ID" ]; then
	info "Looking for the latest successful 'Android build' run on ${ENGINE_REPO}@${ENGINE_BRANCH}"
	RUN_ID="$(api_json "repos/${ENGINE_REPO}/actions/workflows/${ENGINE_WORKFLOW_FILE}/runs" \
		-G --data-urlencode "branch=${ENGINE_BRANCH}" \
		   --data-urlencode "status=success" \
		   --data-urlencode "per_page=1" 2>/dev/null \
		| python3 -c 'import json,sys
try:
    runs = (json.load(sys.stdin).get("workflow_runs") or [])
except Exception:
    runs = []
print(runs[0]["id"] if runs else "")')"
fi

if [ -z "$RUN_ID" ]; then
	warn "no successful 'Android build' run found on ${ENGINE_BRANCH}; building the APK without engine libraries"
	exit 0
fi
info "Using engine run ${RUN_ID}"

# --- resolve the artifact --------------------------------------------------
ARTIFACTS_JSON="$(api_json "repos/${ENGINE_REPO}/actions/runs/${RUN_ID}/artifacts" 2>/dev/null || true)"

# Print the whole inventory while this is still being brought up: a renamed or
# expired artifact is otherwise an invisible difference between two runs.
info "artifacts on run ${RUN_ID}:"
printf '%s' "$ARTIFACTS_JSON" | python3 -c 'import json,sys
try:
    arts = json.load(sys.stdin).get("artifacts") or []
except Exception:
    arts = []
if not arts:
    print("  (none listed)")
for a in arts:
    print("  %-32s id=%-14s %10d bytes%s"
          % (a.get("name"), a.get("id"), a.get("size_in_bytes") or 0,
             "  EXPIRED" if a.get("expired") else ""))
' 2>/dev/null || echo "  (could not parse the artifact list)"

ART="$(printf '%s' "$ARTIFACTS_JSON" | ARTIFACT_NAME="$ARTIFACT_NAME" python3 -c 'import json,os,sys
name = os.environ["ARTIFACT_NAME"]
try:
    arts = json.load(sys.stdin).get("artifacts") or []
except Exception:
    arts = []
for a in arts:
    if a.get("name") == name and not a.get("expired"):
        print(a["id"])
        break
' 2>/dev/null)"

if [ -z "$ART" ]; then
	warn "run ${RUN_ID} has no ${ARTIFACT_NAME} artifact; building the APK without engine libraries"
	exit 0
fi

# --- download --------------------------------------------------------------
# Downloading an artifact requires authentication. Being a public repository
# is not enough: the endpoint answers an anonymous request with a redirect
# from a normal network, but from a GitHub Actions runner it answers 401
# "Requires authentication", because that IP range is shared and the anonymous
# budget for api.github.com is 60 requests an hour. So one of these tokens has
# to be able to read the engine repository:
#
#   ENGINE_ARTIFACT_TOKEN   the intended one: a token with read access to the
#                           engine repository and nothing else
#   GH_TOKEN / API_GITHUB_TOKEN  whatever this repository already had
#   GITHUB_TOKEN            deliberately tried last. Actions scopes it to THIS
#                           repository, so it cannot read the engine's
#                           artifacts -- but the status it returns tells us
#                           whether the problem is credentials or something
#                           else, so it is worth the attempt.
#
# No -f, so a non-200 body is saved and can be shown instead of thrown away.
# curl also strips the Authorization header when a redirect crosses to another
# host, so the token never reaches GitHub's artifact storage.
info "Downloading ${ARTIFACT_NAME} (artifact ${ART})"

try_download() {
	local label="$1" token="$2"
	local -a hdr=(-H "Accept: application/vnd.github+json")
	[ -n "$token" ] && hdr+=(-H "Authorization: Bearer ${token}")
	local code
	# Retries: this endpoint intermittently answers 401 from runner IPs even
	# with a valid token, and the failure mode -- an APK with no libraries that
	# still builds green -- is worse than waiting a few seconds.
	code="$(curl -sS -L "${hdr[@]}" \
		--retry 4 --retry-delay 5 --retry-all-errors --connect-timeout 30 \
		-o "${STAGE}/libs.zip" \
		-w '%{http_code}' \
		"https://api.github.com/repos/${ENGINE_REPO}/actions/artifacts/${ART}/zip" \
		2>"${STAGE}/curl.err")" || code="curl-exit-${?}"
	# stderr, not stdout: this function's return value is captured by the
	# caller, and echoing here would end up inside the status string.
	info "  ${label}: HTTP ${code}, $(wc -c <"${STAGE}/libs.zip" | tr -d ' ') bytes" >&2
	printf '%s' "$code"
}

dl_code=""
dl_label=""
for var in ENGINE_ARTIFACT_TOKEN GH_TOKEN API_GITHUB_TOKEN GITHUB_TOKEN; do
	eval "tok=\${${var}:-}"
	[ -n "$tok" ] || continue
	dl_code="$(try_download "$var" "$tok")"
	dl_label="$var"
	[ "$dl_code" = "200" ] && break
done
if [ "$dl_code" != "200" ]; then
	dl_code="$(try_download anonymous "")"
	dl_label="anonymous"
fi

if [ "$dl_code" != "200" ]; then
	warn "artifact download failed (last status ${dl_code}); building the APK without engine libraries"
	[ -s "${STAGE}/curl.err" ] && head -n 5 "${STAGE}/curl.err" && echo
	if [ -s "${STAGE}/libs.zip" ] && [ "$(wc -c <"${STAGE}/libs.zip")" -lt 4096 ]; then
		warn "response body: $(tr -d '\r\n' <"${STAGE}/libs.zip" | head -c 400)"
	fi
	warn "set ENGINE_ARTIFACT_TOKEN (a token that can read ${ENGINE_REPO}) to include the engine libraries"
	exit 0
fi

info "downloaded $(wc -c <"${STAGE}/libs.zip" | tr -d ' ') bytes"

# Worth recording on every run: an anonymous download works only while the
# shared Actions egress IP is under api.github.com's 60-requests-an-hour
# anonymous budget, so a green build can silently mean "no libraries".
if [ "$dl_label" = "anonymous" ]; then
	warn "fetched anonymously - reliable only while the shared runner IP is under the anonymous rate limit. Set ENGINE_ARTIFACT_TOKEN to make this deterministic."
else
	notice "fetched using ${dl_label}"
fi

unzip -q -o "${STAGE}/libs.zip" -d "${STAGE}/out" || {
	warn "artifact is not a readable zip; building the APK without engine libraries"
	exit 0
}

# What the artifact actually carries. The engine's own libraries are not all
# obvious: libclient.so and libGameUI.so link against libtier0.so,
# libvstdlib.so and libsteam_api.so, none of which are modules the loader
# looks up by name, so they are easy to leave behind -- and a module missing
# its own dependency is a dlopen failure, not a missing-module message.
ARTIFACT_SOS="$(find "${STAGE}/out" -type f -name '*.so' 2>/dev/null | sort)"
info "artifact contains:"
printf '%s\n' "$ARTIFACT_SOS" | while IFS= read -r f; do
	[ -z "$f" ] && continue
	info "  $(basename "$f") ($(wc -c <"$f" | tr -d ' ') bytes)"
done
notice "artifact libraries: $(printf '%s\n' "$ARTIFACT_SOS" | xargs -r -n1 basename | sort | tr '\n' ' ')"

# --- stage and verify ------------------------------------------------------
mkdir -p "$ABI_DIR"
staged=0
missing=0
bad=0
optional_missing=0

# Ship every AArch64 shared object the artifact carries, not only the modules
# the loader looks up by name. The four named ones are still checked
# individually below; anything else is cargo they depend on.
while IFS= read -r src; do
	[ -z "$src" ] && continue
	name="$(basename "$src")"
	read -r class machine <<<"$(elf_info "$src")"
	if [ "$class" != "$EXPECT_CLASS" ] || [ "$machine" != "$EXPECT_MACHINE" ]; then
		warn "dropping ${name}: ${class}/${machine}, not ${EXPECT_CLASS}/${EXPECT_MACHINE} (AArch64)"
		continue
	fi
	cp "$src" "${ABI_DIR}/${name}" || exit 1
	staged=$((staged + 1))
done <<<"$ARTIFACT_SOS"

for m in "${MODULES[@]}"; do
	required=0
	for r in "${REQUIRED_MODULES[@]}"; do
		[ "$r" = "$m" ] && required=1
	done

	# Already copied by the loop above; this pass only reports.
	if [ ! -f "${ABI_DIR}/${m}" ]; then
		if [ "$required" = "1" ]; then
			fail "engine artifact is missing ${m}"
			missing=$((missing + 1))
		else
			warn "engine artifact has no ${m} (optional - the Android launcher may not need the VGUI menu)"
			optional_missing=$((optional_missing + 1))
		fi
		continue
	fi

	info "staged ${m} ($(wc -c <"${ABI_DIR}/${m}" | tr -d ' ') bytes)"
done

info "Staged ${staged} libraries into ${ABI_DIR} (${#REQUIRED_MODULES[@]} of them are required modules)"

# --- resolve what the modules link against --------------------------------
# The engine's libraries are not self-contained. They link libSDL2.so, which
# the engine's build finds in its own lib/ submodule -- nillerusr/source-engine-libs,
# the repo wscript:648 installs prebuilts from -- but which never reaches the
# artifact, because the engine's Collect libraries step only gathers the four
# named modules.
#
# A module whose dependency is absent is a dlopen failure on the phone, not a
# missing-module message, and there is no adb to read it from. So walk the
# modules' DT_NEEDED and fetch whatever is neither shipped nor a platform
# library from that submodule -- the same prebuilt the engine linked against,
# not a rebuild that might drift.

read_needed() {
	local so="$1"
	if command -v readelf >/dev/null 2>&1; then
		readelf -d "$so" 2>/dev/null
	elif command -v objdump >/dev/null 2>&1; then
		objdump -p "$so" 2>/dev/null
	else
		return 0
	fi | sed -n 's/.*NEEDED.*\[\([^]]*\)\].*/\1/p'
}

fetch_prebuilt() {
	local name="$1" out="$2" code
	code="$(curl -sS -L -H "Accept: application/vnd.github.raw" \
		--retry 3 --retry-delay 3 --retry-all-errors --connect-timeout 30 \
		-o "$out" -w '%{http_code}' \
		"https://api.github.com/repos/${EXTRA_LIBS_REPO}/contents/${EXTRA_LIBS_PATH}/${name}?ref=${EXTRA_LIBS_REF}" \
		2>/dev/null)" || return 1
	[ "$code" = "200" ] || return 1
	[ -s "$out" ] || return 1
}

resolved=0
if ! command -v readelf >/dev/null 2>&1 && ! command -v objdump >/dev/null 2>&1; then
	warn "no readelf or objdump here, so module dependencies cannot be checked"
else
	# Bounded passes: a library fetched on one pass may itself need another.
	for pass in 1 2 3; do
		wanted=()
		while IFS= read -r so; do
			[ -f "$so" ] || continue
			while IFS= read -r n; do
				[ -z "$n" ] && continue
				[ -f "${ABI_DIR}/${n}" ] && continue
				case "$PLATFORM_LIBS" in
					*" ${n} "*) continue ;;
				esac
				wanted+=("$n")
			done < <(read_needed "$so")
		done < <(find "$ABI_DIR" -type f -name '*.so' 2>/dev/null | sort)

		# Unique, preserving nothing in particular.
		uniq_wanted=()
		while IFS= read -r n; do
			[ -z "$n" ] && continue
			uniq_wanted+=("$n")
		done < <(printf '%s\n' "${wanted[@]:-}" | sort -u)

		[ "${#uniq_wanted[@]}" -eq 0 ] && break

		progress=0
		for n in "${uniq_wanted[@]}"; do
			out="${STAGE}/extra-${n}"
			if ! fetch_prebuilt "$n" "$out"; then
				info "  ${n}: not in ${EXTRA_LIBS_REPO}/${EXTRA_LIBS_PATH}"
				continue
			fi
			read -r class machine <<<"$(elf_info "$out")"
			if [ "$class" != "$EXPECT_CLASS" ] || [ "$machine" != "$EXPECT_MACHINE" ]; then
				warn "  ${n} from ${EXTRA_LIBS_REPO} is ${class}/${machine}, not ${EXPECT_CLASS}/${EXPECT_MACHINE}; leaving it out"
				rm -f "$out"
				continue
			fi
			cp "$out" "${ABI_DIR}/${n}" || exit 1
			info "  ${n}: fetched from ${EXTRA_LIBS_REPO} ($(wc -c <"${ABI_DIR}/${n}" | tr -d ' ') bytes)"
			resolved=$((resolved + 1))
			progress=1
		done

		[ "$progress" = "0" ] && break
	done
fi

info "Resolved ${resolved} extra libraries from ${EXTRA_LIBS_REPO}"

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
	{
		echo "### Engine libraries"
		echo
		echo "Engine run: \`${RUN_ID}\` on \`${ENGINE_REPO}@${ENGINE_BRANCH}\`"
		echo
		echo "| module | size | ELF |"
		echo "| --- | --- | --- |"
		for m in "${MODULES[@]}"; do
			if [ -f "${ABI_DIR}/${m}" ]; then
				echo "| ${m} | $(wc -c <"${ABI_DIR}/${m}" | tr -d ' ') | $(elf_info "${ABI_DIR}/${m}") |"
			else
				echo "| ${m} | missing | - |"
			fi
		done
	} >>"$GITHUB_STEP_SUMMARY"
fi

if [ "$missing" -gt 0 ] || [ "$bad" -gt 0 ]; then
	exit 1
fi
if [ "$staged" -eq 0 ]; then
	exit 1
fi

echo "ENGINE_RUN_ID=${RUN_ID}" >>"${GITHUB_ENV:-/dev/null}"
