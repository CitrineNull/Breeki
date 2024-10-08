#!/bin/bash
set -eo pipefail

zfs load-key tank/private
zfs mount tank/private
# su -c "media-server start private" podman-user
