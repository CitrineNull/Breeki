#!/bin/bash
set -eo pipefail

# Simply exits with 0 if mounted, and 1 if not

MOUNT=$1
case $MOUNT in

    # Check that tank/public is mounted
    "public")
        /usr/bin/zfs get mounted tank/public | /usr/bin/grep yes 
        exit $?
        ;;
    
    # Check that tank/private is decrypted and mounted
    "private")
        /usr/bin/zfs get mounted tank/private | /usr/bin/grep yes 
        exit $?
        ;;

esac
