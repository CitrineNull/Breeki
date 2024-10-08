#!/bin/bash
set -eo pipefail

DIRECTIVE=${1:-"--help"}
SERVICES=$2

SCRIPT_PATH=$(realpath $0)
SCRIPT_DIR=$(dirname $SCRIPT_PATH)
INSTALL_DIR=$(dirname $SCRIPT_DIR)

SYMLINK_BIN_DIR="/usr/local/bin"
SYMLINK_SBIN_DIR="/usr/local/sbin"

COMPOSE_MEDIA="${INSTALL_DIR}/container-compose.media.yaml"
COMPOSE_UTILS="${INSTALL_DIR}/container-compose.utils.yaml"
COMPOSE_PRIVATE="${INSTALL_DIR}/container-compose.private.yaml"

USAGE="
Usage: media-server.sh [help|start|stop|down|start|restart|destroy|install|uninstall|(ps|ls)] [utils|(public|media)|private|(all|everything)|public-only|private-only]

Directives:
help              Displays this help message
restart           Restart the services
stop              Stops the services
start             Starts the services
destroy           Destroy the containers, keeping the configuration files
destroy           Destroy the containers and their images, keeping the configuration files
install           Create a symlink for this script in ${SYMLINK_BIN_DIR}/, and add UFW rules for services (requires root)
uninstall         Remove the symlink for this script in ${SYMLINK_BIN_DIR}/, and remove UFW rules for services (requires root)
ps | ls           Show the containers currently active in the stack

Services:
utils             Only utility services
public | media    Utility and public media services
private           Utility and private services
all | everything  All services (public, private and utility)
public-only       Only public services (they still need the utils, use with caution)
private-only      Only private services (they still need the utils, use with caution)
"

install() {

    # Get the desired user
    read -p "What user will be running the containers?: " username

    # Check the user exists
    if id -u "$username" &>/dev/null; then
        puid=$(id -u "$username");
        pgid=$(id -g "$username");
    else
        send_error_message "The user \"$username\" doesn't exist!"
        exit 1
    fi

    # Create a symlink to this script, as well as check-mount.sh, in $PATH
    destination="${SYMLINK_BIN_DIR}/media-server"
    ln -sf $SCRIPT_PATH $destination
    ln -sf "${SCRIPT_DIR}/check-mount.sh" ${SYMLINK_BIN_DIR}/check-mount
    ln -sf "${SCRIPT_DIR}/decrypt.sh" ${SYMLINK_SBIN_DIR}/decrypt
    echo "Created a symlink to this script ($SCRIPT_PATH) at ${destination}"
    echo "If ${SYMLINK_BIN_DIR} is in your PATH, you should be able to run this script with just 'media-server [...args]'"
    echo

    # Create UFW rules to allow LAN access
    ${INSTALL_DIR}/scripts/configure-ufw.sh install
    echo "Added UFW rules, current status:"
    ufw status verbose
    echo

    # List of config directories that our containers will need to mount
    declare -a conf_dirs=("bazarr"
                          "caddy"
                          "code-server"
                          "dnsmasq"
                          "homepage"
                          "jellyfin"
                          "jellyseerr"
                          "kapowarr"
                          "kavita"
                          "lidarr"
                          "mariadb"
                          "mongodb"
                          "nextcloud"
                          "pihole"
                          "portainer"
                          "qbittorrent"
                          "qbittorrent-private"
                          "radarr"
                          "readarr"
                          "redis-nextcloud"
                          "redis-overleaf"
                          "sonarr"
                          "unbound"
    )

    # Create config folders for services (Docker automatically creates folders for volumes if they don't exist, Podman doesn't)
    for sub_dir in "${conf_dirs[@]}"
    do
        mkdir -p "${INSTALL_DIR}/config/${subdir}"
    done

    # Make the media server files owned by the chosen user
    chown -R $username:$username $INSTALL_DIR

    # Show the user the progress as the images are pulled
    # Starting the services straight away results in a concerning delay with no output since the images may need to download
    su -c "media-server pull all" $username

    # Enable the Podman API Socket for the chosen user, and the other services system-wide
    systemctl -M "${username}@" --user enable --now podman.socket
    systemctl -M "${username}@" --user enable --now "${INSTALL_DIR}/services/*"
    
    echo "The installation is complete, the services should now be running if everything worked:"

    su -c "podman ps" $username
}

uninstall() {

    # Get the desired user
    read -p "What user are you uninstalling for?: " username

    # Check the user exists
    if id -u "$username" &>/dev/null; then
        puid=$(id -u "$username");
        pgid=$(id -g "$username");
    else
        send_error_message "The user \"$username\" doesn't exist!"
        exit 1
    fi

    # Disable the systemd services for that user
    systemctl -M "${username}@" --user disable --now podman.socket
    systemctl --system disable --now "${INSTALL_DIR}/services/*"

    # Delete the containers using this script
    su -c "media-server destroy all"

    # Delete the symlink to this script
    rm -f $"${SYMLINK_BIN_DIR}/media-server" "${SYMLINK_BIN_DIR}/check-mount ${SYMLINK_BIN_DIR}/decrypt"
    echo "Removed symlinks from $SYMLINK_BIN_DIR"

    # Remove the UFW rules that were made
    ${INSTALL_DIR}/scripts/configure-ufw.sh uninstall
    echo "Deleted UFW rules, current status:"
    ufw status verbose
    echo

    echo "The uninstallation is complete"
}

case $DIRECTIVE in

    # Show usage instructions
    "--help" | "help")
        echo "media-server - Media server management script ${USAGE}"
        exit $?
        ;;

    # Create a symlink for this script in PATH and add UFW rules for services
    "install")
        install
        exit $?
        ;;
        
    # Remove the symlink and UFW rules
    "uninstall")
        uninstall
        exit $?
        ;;
    
    # Handle these after building the docker compose command string
    "start" | "stop" | "restart" | "destroy" | "down" | "pull" | "ps" | "ls")
        ;;
    
    # Catch invalid options
    *)
        echo "Unrecognised directive - pick from: help | start | stop | restart | destroy | install | uninstall"
        exit $?
        ;;
esac

COMPOSE="podman-compose"
case $SERVICES in

    # Only utility services
    "utils")
        COMPOSE="${COMPOSE} -f ${COMPOSE_UTILS}"
        ;;

    # Media and utils (public services)
    "public" | "media")
        COMPOSE="${COMPOSE} -f ${COMPOSE_UTILS} -f ${COMPOSE_MEDIA}"   
        ;;

    # Private and utils (private services)
    "private")
        COMPOSE="${COMPOSE} -f ${COMPOSE_UTILS} -f ${COMPOSE_PRIVATE}"   
        ;;

    # Media and utils (public services)
    "all" | "everything")
        COMPOSE="${COMPOSE} -f ${COMPOSE_UTILS} -f ${COMPOSE_MEDIA} -f ${COMPOSE_PRIVATE}"   
        ;;

    # Only media (DON'T USE UNLESS YOU'VE ALREADY SORTED OUT UTILS)
    "public-only" | "media-only")
        COMPOSE="${COMPOSE} -f ${COMPOSE_MEDIA}"
        ;;

    # Only private (DON'T USE UNLESS YOU'VE ALREADY SORTED OUT UTILS)
    "private-only")
        COMPOSE="${COMPOSE} -f ${COMPOSE_PRIVATE}"
        ;;

    # Catch invalid options
    *)
        echo "Unrecognised option for ${DIRECTIVE} - ${SERVICES}"
        echo "pick from: utils | (public|media) | private | (all|everything)"
        exit 1
        ;;
esac

case $DIRECTIVE in

    # Start the selected services in background
    "start" | "up")
        $COMPOSE up -d
        exit $?
        ;;
    
    # Stop the selected services
    "stop")
        $COMPOSE stop
        exit $?
        ;;

    # Destroy the selected containers
    "down")
        $COMPOSE down
        exit $?
        ;;

    # Restart the selected services
    "restart")
        $COMPOSE restart
        exit $?
        ;;

    # Destroy the selected services and their images
    "destroy")
        $COMPOSE down
        podman system prune -af
        exit $?
        ;;

    # Download images without starting containers
    "pull")     
        $COMPOSE pull
        exit $?
        ;;

        # Download images without starting containers
    "ps" | "ls")     
        $COMPOSE ps
        exit $?
        ;;

esac
