#!/bin/sh
chmod 755 /home/bin/htop
ls -l /home/bin/htop
sha256sum /home/bin/htop
echo "=== loaded objects ==="
LD_TRACE_LOADED_OBJECTS=1 /home/bin/htop 2>&1 | head
echo "=== version ==="
TERM=linux /home/bin/htop --version 2>&1 | head -3
echo "=== df /home ==="; df /home | tail -1