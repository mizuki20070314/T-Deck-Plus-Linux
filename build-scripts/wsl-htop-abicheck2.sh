#!/usr/bin/env bash
awk '{print $1}' /tmp/mine.syms  | sort -u > /tmp/mine.names
awk '{print $1}' /tmp/board.syms | sort -u > /tmp/board.names
echo "--- names only in mine ---";         comm -23 /tmp/mine.names /tmp/board.names
echo "--- names only on the board ---";    comm -13 /tmp/mine.names /tmp/board.names