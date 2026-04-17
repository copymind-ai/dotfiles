#!/usr/bin/env bash
# Shortcut: delegates to tests/run.sh
exec "$(dirname "$0")/tests/run.sh" "$@"
