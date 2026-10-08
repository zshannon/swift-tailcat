#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/environment.sh"
go version
go install "golang.org/x/mobile/cmd/gobind@$TAILCAT_MOBILE_VERSION"
go install "golang.org/x/mobile/cmd/gomobile@$TAILCAT_MOBILE_VERSION"
gomobile init
