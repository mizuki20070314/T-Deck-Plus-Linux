#!/bin/bash
# tidy: drop the scratch worktree and temp build dirs; show the final state of the main tree
cd ~/esp32s3/src/linux-fork
git worktree remove --force ~/esp32s3/src/linux-wt 2>/dev/null; git worktree prune
rm -rf /tmp/kout-a64 /tmp/kout-base /tmp/kout-amoled /tmp/wsav* /tmp/sh8601.txt
git log --oneline | head -5
echo "--- out dir ---"; ls -l ~/esp32s3/out