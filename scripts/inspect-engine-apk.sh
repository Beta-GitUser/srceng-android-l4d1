#!/usr/bin/env bash
# What native libraries does the engine's own debug APK carry?
#
# The engine publishes android-aarch64-libraries (the modules) and
# android-aarch64-debug-apk (a working APK it builds itself). When a module
# needs a library that the libraries artifact does not carry -- libSDL2.so,
# currently -- the question is whether that library is obtainable at all, and
# the engine's own APK is the most likely place it exists: it was linked
# against the very build we are consuming.
#
# Investigation, not build plumbing: report the inventory and stop.

set -uo pipefail

ENGINE_REPO="${ENGINE_REPO:-Beta-GitUser/source-engine-l4d1}"
ENGINE_BRANCH="${ENGINE_BRANCH:-arena/410ac3e6-source-engine-l4d1}"
ENGINE_WORKFLOW_FILE="${ENGINE_WORKFLOW_FILE:-android.yml}"
RUN_ID="${ENGINE_RUN_ID:-}"
APK_ARTIFACT="${APK_ARTIFACT:-android-aarch64-debug-apk}"
WANT="${WANT:-libSDL2.so}"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

info()   { echo "$*"; }
warn()   { echo "::warning::$*"; }
notice() { echo "::notice::$*"; }

api_json() {
	local path="$1"; shift
	local tok; tok="$(best_token)"
	local -a hdr=(-fsSL -H "Accept: application/vnd.github+json")
	[ -n "$tok" ] && hdr+=(-H "Authorization: Bearer ${tok}")
	curl "${hdr[@]}" "$@" "https://api.github.com/${path}"
}

best_token() {
	local var tok
	for var in ENGINE_ARTIFACT_TOKEN GH_TOKEN API_GITHUB_TOKEN GITHUB_TOKEN; do
		eval "tok=\${${var}:-}"
		[ -n "$tok" ] && { printf '%s' "$tok"; return 0; }
	done
	return 0
}

if [ -z "$RUN_ID" ]; then
	RUN_ID="$(api_json "repos/${ENGINE_REPO}/actions/workflows/${ENGINE_WORKFLOW_FILE}/runs" \
		-G --data-urlencode "branch=${ENGINE_BRANCH}" \
		   --data-urlencode "status=success" \
		   --data-urlencode "per_page=1" 2>/dev/null \
		| python3 -c 'import json,sys
try:
    r = json.load(sys.stdin).get("workflow_runs") or []
except Exception:
    r = []
print(r[0]["id"] if r else "")')"
fi
[ -z "$RUN_ID" ] && { warn "no successful engine run found"; exit 0; }

ART="$(api_json "repos/${ENGINE_REPO}/actions/runs/${RUN_ID}/artifacts" 2>/dev/null \
	| APK_ARTIFACT="$APK_ARTIFACT" python3 -c 'import json,os,sys
want = os.environ["APK_ARTIFACT"]
try:
    arts = json.load(sys.stdin).get("artifacts") or []
except Exception:
    arts = []
for a in arts:
    if a.get("name") == want and not a.get("expired"):
        print(a["id"]); break
' 2>/dev/null)"

if [ -z "$ART" ]; then
	notice "run ${RUN_ID} publishes no ${APK_ARTIFACT}"
	exit 0
fi

code="$(curl -sS -L -H "Accept: application/vnd.github+json" \
	--retry 4 --retry-delay 5 --retry-all-errors \
	-o "${STAGE}/apk.zip" -w '%{http_code}' \
	"https://api.github.com/repos/${ENGINE_REPO}/actions/artifacts/${ART}/zip" 2>/dev/null)" || code="curl-exit-${?}"

if [ "$code" != "200" ]; then
	warn "could not download ${APK_ARTIFACT} (HTTP ${code})"
	exit 0
fi

unzip -q -o "${STAGE}/apk.zip" -d "${STAGE}/apk" || { warn "not a readable zip"; exit 0; }

APK="$(find "${STAGE}/apk" -name '*.apk' -type f -print -quit)"
if [ -z "$APK" ]; then
	warn "${APK_ARTIFACT} contains no .apk"
	exit 0
fi

info "engine APK: $(basename "$APK"), $(wc -c <"$APK" | tr -d ' ') bytes"
mapfile -t libs < <(unzip -l "$APK" 2>/dev/null | awk '/lib\/.*\.so$/ {print $4}')

if [ "${#libs[@]}" -eq 0 ]; then
	notice "the engine APK carries no native libraries"
	exit 0
fi

notice "engine APK native libraries (${#libs[@]}): $(printf '%s\n' "${libs[@]}" | xargs -r -n1 basename | sort | tr '\n' ' ')"

found=0
for l in "${libs[@]}"; do
	if [ "$(basename "$l")" = "$WANT" ]; then
		found=1
		notice "${WANT} is present in the engine APK at ${l}"
	fi
done
[ "$found" = "0" ] && warn "${WANT} is not in the engine APK either"

exit 0
