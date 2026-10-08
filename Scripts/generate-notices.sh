#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/environment.sh"
python3 "$TAILCAT_ROOT/Scripts/generate-notices.py"
