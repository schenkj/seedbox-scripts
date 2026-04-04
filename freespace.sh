#!/bin/bash
set -e

# Required free space in KB (100 GB)
reqSpace=$((100 * 1024 * 1024))

# Extract used and limit (in KB)
read used limit <<< $(quota | awk 'NR==3 {print $2, $3}')

free_kb=$((limit - used))

if [[ $free_kb -le $reqSpace ]]; then
  exit 1
fi

exit 0
