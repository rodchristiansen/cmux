#!/bin/bash
set -e
cd "$(dirname "$0")"
go build -ldflags="-s -w" -trimpath -o cmuxd-go .
PTY_CWD="$(pwd)/../web" exec ./cmuxd-go --port "${1:-3778}"
