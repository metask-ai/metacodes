#!/bin/bash
# Reward 1 only for the exact file the scripted Bash call writes.
if [ "$(cat /app/hello.txt 2>/dev/null)" = "Hello from metacodes" ]; then
  echo 1 > /logs/verifier/reward.txt
else
  echo 0 > /logs/verifier/reward.txt
fi
