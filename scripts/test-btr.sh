#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
node Tests/BTR/oracle.cjs
: > build/test-port.txt
python3 Tests/BTR/server.py build/test-port.txt >build/test-server.log 2>&1 &
server_pid=$!
trap 'kill "$server_pid" 2>/dev/null || true' EXIT
for attempt in {1..100}; do
  if [[ -s build/test-port.txt ]]; then break; fi
  sleep 0.1
done
swiftc -swift-version 5 -parse-as-library -o build/btr-tests \
  BilibiliLive/Component/Player/MediaRangeTransport.swift \
  BilibiliLive/Component/Player/MediaRangeDownloader.swift \
  BilibiliLive/Component/Player/BTRPlayback.swift \
  BilibiliLive/Component/Player/BTRPolicy.swift \
  BilibiliLive/Component/Player/BTRHTTPClient.swift Tests/BTR/Main.swift
./build/btr-tests Tests/BTR/oracle.json "$(cat build/test-port.txt)"
