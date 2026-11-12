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

EXPECT_CLASS="ELF64"
EXPECT_MACHINE="183"   # EM_AARCH64

MODULES=(libclient.so libserver.so liblauncher.so libGameUI.so)

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

warn() { echo "::warning::$*"; }
info() { echo "$*"; }
fail() { echo "::error::$*"; }

# Quiet variant of curl for API calls. -f makes HTTP errors visible to the caller
# instead of silently writing an error document to stdout.
api_json() {
	local path="$1"; shift
	local -a hdr=(-fsSL -H "Accept: application/vnd.github+json")
	if [ -n "${GITHUB_TOKEN:-}" ]; then
		hdr+=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
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
# Deliberately anonymous: the -L chain follows GitHub's redirect to its
# artifact storage, and sending our token along would leak it to that host.
# No -f, so a non-200 body is saved and can be shown instead of thrown away.
info "Downloading ${ARTIFACT_NAME} (artifact ${ART})"
dl_code="$(curl -sS -L \
	-H "Accept: application/vnd.github+json" \
	-o "${STAGE}/libs.zip" \
	-w '%{http_code}' \
	"https://api.github.com/repos/${ENGINE_REPO}/actions/artifacts/${ART}/zip" \
	2>"${STAGE}/curl.err")" || dl_code="curl-exit-${?}"

if [ "$dl_code" != "200" ]; then
	warn "artifact download failed (status ${dl_code}); building the APK without engine libraries"
	[ -s "${STAGE}/curl.err" ] && head -n 5 "${STAGE}/curl.err" && echo
	if [ -s "${STAGE}/libs.zip" ] && [ "$(wc -c <"${STAGE}/libs.zip")" -lt 4096 ]; then
		warn "response body: $(tr -d '\r\n' <"${STAGE}/libs.zip" | head -c 400)"
	fi
	exit 0
fi

info "downloaded $(wc -c <"${STAGE}/libs.zip" | tr -d ' ') bytes"

unzip -q -o "${STAGE}/libs.zip" -d "${STAGE}/out" || {
	warn "artifact is not a readable zip; building the APK without engine libraries"
	exit 0
}

# --- stage and verify ------------------------------------------------------
mkdir -p "$ABI_DIR"
staged=0
missing=0
bad=0

for m in "${MODULES[@]}"; do
	src="$(find "${STAGE}/out" -type f -name "$m" -print -quit 2>/dev/null)"
	# Case-insensitive fallback: only libGameUI.so should ever need it, and only
	# if the engine renames the target. The staged name stays canonical.
	[ -z "$src" ] && src="$(find "${STAGE}/out" -type f -iname "$m" -print -quit 2>/dev/null)"

	if [ -z "$src" ]; then
		fail "engine artifact is missing ${m}"
		missing=$((missing + 1))
		continue
	fi

	read -r class machine <<<"$(elf_info "$src")"
	if [ "$class" != "$EXPECT_CLASS" ] || [ "$machine" != "$EXPECT_MACHINE" ]; then
		fail "${m} is ${class}/${machine}, expected ${EXPECT_CLASS}/${EXPECT_MACHINE} (AArch64) - the cross-compile went wrong"
		bad=$((bad + 1))
		continue
	fi

	cp "$src" "${ABI_DIR}/${m}" || exit 1
	info "staged ${m} ($(wc -c <"${ABI_DIR}/${m}" | tr -d ' ') bytes)"
	staged=$((staged + 1))
done

# Anything else the artifact carried is dropped on purpose: the carrier ships
# the four modules the loader looks for, nothing more.

info "Staged ${staged}/${#MODULES[@]} modules into ${ABI_DIR}"

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
