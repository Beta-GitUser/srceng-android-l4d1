#!/usr/bin/env bash
# Local build. CI does not use this; it calls scripts/workflow.sh directly.
#
# ANDROID_HOME has to point at an SDK that still ships the legacy Ant rules
# ($ANDROID_HOME/tools/ant/build.xml). A current commandline-tools install does
# not, which is the usual reason `ant` fails on a fresh machine --
# scripts/setup-android-sdk.sh will produce one.
set -euo pipefail

: "${ANDROID_HOME:?set ANDROID_HOME to an Android SDK with tools/ant/build.xml (see scripts/setup-android-sdk.sh)}"
export ANDROID_HOME

DE="${DEPLOY_BRANCH:-srceng-l4d1}" \
COMMIT="$(git rev-parse HEAD)" \
scripts/workflow.sh
