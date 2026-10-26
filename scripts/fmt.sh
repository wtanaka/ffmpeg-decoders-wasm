#!/bin/sh
# Formats all files to 80 columns: rustfmt (.rustfmt.toml) for Rust, dprint
# (.dprint.json) for Markdown, TOML and YAML, shfmt for shell scripts.
#
#   sh scripts/fmt.sh [--check]
set -eu
cd "$(dirname "$0")/.."
if [ "${1:-}" = --check ]; then
  rustfmt_args="--check"
  dprint_cmd="check"
  shfmt_mode="-d"
else
  rustfmt_args=""
  dprint_cmd="fmt"
  shfmt_mode="-w"
fi
# shellcheck disable=SC2086
find crates -name '*.rs' -not -path '*/target/*' -print0 \
  | xargs -0 rustfmt --edition 2021 --config-path .rustfmt.toml $rustfmt_args
dprint "$dprint_cmd"
shfmt -i 2 -ci -bn -sr "$shfmt_mode" scripts/*.sh
