#!/bin/bash
# Build the Kokkos Tools allocation logger next to its source (login node):
#   nicola/tools/build_kp_big_alloc.sh
set -e
cd "$(dirname "${BASH_SOURCE[0]}")"

if ! type module >/dev/null 2>&1; then
    for f in /etc/profile.d/modules.sh /usr/share/Modules/init/bash; do
        [ -r "$f" ] && . "$f" && break
    done
fi
module load gcc/13.1.0

g++ -O2 -std=c++17 -shared -fPIC -o kp_big_alloc.so kp_big_alloc.cpp
echo "built $(pwd)/kp_big_alloc.so"
