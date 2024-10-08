# Full Self-Hosted Media Center Guide

This is a guide for setting up a fully self-hosted media center using Podman (or Docker).
You can automatically download and watch all your favourite movies and TV Shows,
as well as music, comics, ebooks, and pretty much anything else you want.

Of course, this is strictly for materials found in the public domain.
Piracy is a crime, [you wouldn't steal a car](https://www.youtube.com/watch?v=HmZm8vNHBSU) :P

It features many of the *arr suite of services, as well as many other services:

- Jellyfin
- Jellyseer
- Sonarr
- Radarr
- Lidarr
- Readarr
- Bazarr
- Prowlarr
- Flaresolverr
- Kapowarr
- Kavita
- qBittorrent
- Pi-Hole
- Unbound
- Samba
- Caddy
- Homepage
- Portainer
- Nextcloud
- Overleaf

Pi-Hole is used to provide ad-blocking to our entire network, and uses Unbound as an upstream recursive DNS resolver.
Caddy acts as a reverse proxy, giving us automatic TLS with self-signed certificates and replacing annoying port numbers with memorable subdomains.

While this guide is my personal set up, you can make your own modifications as well, such as:

- Swapping Jellyfin+Jellyseerr for Plex/Ombi+Overseerr
- Using different clients than qBittorrent such as Deluge
- Configuring your SMB shares differently
- Changing Podman for Docker, or going from rootless to rootful containers.

This initially started off with me using [YAMS](https://yams.media/), a simpler media server set up than this one.
However as I kept making modifications, adding services, and eventually transitioned the whole thing to Podman,
it became something else entirely.
This guide uses a rootless Podman setup, so if anything it would be easier to go rootful or switch to Docker.

# First steps

This guide was created on a fresh install of Debian Bookworm.
First make sure everything is up-to-date by updating your apt repositories:

```bash
sudo apt update && sudo apt upgrade
```

Set up automatic security updates:

```bash
sudo apt install unattended-upgrades apt-listchanges
```

The defaults already have the minimal configuration for security updates,
we just need to add auto-reboot for updates that require them:
You can create a new file such as `/etc/apt/apt.conf.d/52unattended-upgrades` or modify `/etc/apt/apt.conf.d/50unattended-upgrades`:

```
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "06:00";
```

# Creating a ZFS File System

If you've already got a file system and you're ready to go, [skip ahead](#getting-podman-ready).

## Motivation

I chose ZFS for my main media storage as it fits my requirements for this set up pretty well.
I have 4 10TB drives, and I wanted:

- Separate public and private filesystems
- My public files to be accessible even after reboots since most of my media services rely on them
- Enough redundancy to survive the failure of 1 of my drives
- To share that parity between both public and private such that I wouldn't need two separate RAID arrays
- To potentially expand the number of drives in the future
- To manage how much of my storage the public filesystem can hog 
- Compression and possibly also deduplication
- My private files to be encrypted at rest
  - There's no point in using a keyfile stored on the boot drive as anyone could just read it with root or physical access
  - I didn't want to use TPM only either as it has the same problem with physical access.
  - This pretty much leaves a TPM+PIN setup like you can do with Bitlocker, or just a password prompt on boot which is easier.

Two ideas came to mind, either:

1. Create a RAID5 array with `mdadm`, create two logical partitions with `lvm`, and use LUKS on one of them
2. Use ZFS which does it all in one place

I was conflicted about ZFS despite the hype as the ability to add a single drive to a RAIDZ array wasn't there,
but then [this happened](https://github.com/openzfs/zfs/pull/15022).
This change is expected to be included in [ZFS 2.3.0](https://github.com/openzfs/zfs/releases/tag/zfs-2.3.0-rc1)

## Set Up

First, install any missing dependencies and then ZFS:

```bash
sudo apt-add-repository contrib -y
sudo apt update
sudo apt install linux-headers-$(uname -r) linux-image-amd64 kmod -y
sudo apt install zfsutils-linux zfs-auto-snapshot -y
```

Next, form a RAIDZ1 (kind of equivalent to RAID5) pool out of the disks:

```bash
sudo zpool create tank raidz /dev/sdb /dev/sdc /dev/sdd /dev/sde
```

Create the public and private filesystems with compression (LZ4) and deduplication.
Technically they're called "datasets", but hey ¯\\\_(ツ)\_/¯, who's gonna stop me?

```bash
sudo zfs set compression=on tank
sudo zfs set dedup=on tank
sudo zfs create tank/public
sudo zfs create -o encryption=on -o keysource=passphrase,prompt tank/private
```

We can give the private filesystem a reservation and/or the public filesystem a quota.
This will cap the maximum size of public and entitle private to a minimum amount of storage:

```bash
sudo zfs set quota=12T tank/public
sudo zfs set reservation=12T tank/private
```

Optionally, you change the mount paths for the two filesystems to somewhere else, for example `/mnt/...`

```bash
sudo zfs set mountpoint=none tank
sudo zfs set mountpoint=/mnt/public tank/public
sudo zfs set mountpoint=/mnt/private tank/private
```

The final step is to make sure we don't have permission to write to the mountpoint when the ZFS dataset isn't mounted.
This should help you avoid accidentally writing plaintext to your disk when the dataset isn't decrypted and mounted.

```bash
sudo zfs umount -a
sudo mkdir /mnt/private /mnt/public
sudo chown -R nobody:nogroup /mnt/private/ /mnt/public
sudo chmod -R a-rwx /mnt/private/ /mnt/public
sudo chattr +i /mnt/private /mnt/public
sudo zfs mount -a
```

The private filesystem will need to be manually decrypted and mounted on every reboot.
For convenience, you can add a script somewhere in your `$PATH` to make this slighly easier.
For example, create a script at `/usr/local/sbin/decrypt` with execution permissions with the following contents:

```bash
#!/bin/bash
set -eo pipefail

zfs load-key tank/private
zfs mount tank/private
```

This script can then be run with just `sudo decrypt`, and will prompt you for your password.

Finally, we can enable automatic snapshots using the `zfs-auto-snapshots` package we installed earlier.
Add the following to your root crontab with `sudo crontab -e`:

```cron
00 * * * * root /usr/sbin/zfs-auto-snapshot -q -g --label=hourly --keep=24 //
00 6 * * * root /usr/sbin/zfs-auto-snapshot -q -g --label=daily --keep=14 //
00 6 * * 0 root /usr/sbin/zfs-auto-snapshot -q -g --label=weekly --keep=4 //
00 6 1 * * root /usr/sbin/zfs-auto-snapshot -q -g --label=monthly --keep=18 //
```

This takes snapshots hourly, as well as at 6am daily, weekly, and monthly.
Make sure the path to `zfs-auto-snapshot` is correct for your system by running `sudo which zfs-auto-snapshot`.
All we need to do now is enable snapshots on our datasets:

```bash
sudo zfs set com.sun:auto-snapshot=true tank/public
sudo zfs set com.sun:auto-snapshot=true tank/private
```

And that's all for setting up our media file system.
Containers and configurations are stored on a seperate SSD as it makes everything much faster,
and only the bulk of the media is stored on the ZFS HDDs, but this is easily configurable to taste later on.

# Getting Podman Ready

## A Little Comparison of Podman vs Docker

I want to run my containers using a non-root user on the host as well as a non-root user in the container.
Unfortunately, Docker and UFW do not play nicely together. When you expose a port with Docker,
it will do absolutely everything in it's power to punch through every firewall rule you've made to do it
(although this is fixable, as [described further down](#using-docker-with-ufw)).

That's not to say Podman doesn't have it's disadvantages either.
Just some of the issues I ran into while transitioning from Docker to Podman include:

- While the native support for SELinux is pretty good, AppArmor doesn't work at all when you're running Podman rootless
([discussion on Github](https://github.com/containers/podman/pull/19303) started over 2 years ago)
- The `:idmap=...` flags for volumes doesn't work with `podman-compose` (also been a problem for [over a year](https://github.com/containers/podman-compose/issues/773))
- Detailed documentation can be scarce for some usages, especially compared to Docker which everyone has heard of.
- It's also generally much harder to get volumes working due to the intricate permission management required.

Nevertheless, who doesn't like a little challenge,
so I transitioned the entire setup to Podman after getting it working in Docker since I'm a glutton for punishment.

## Installing Podman and Compose

Next we need to install Podman, and either `docker-compose` or `podman-compose`.
I personally chose `podman-compose`, but `docker-compose` has nicer output.
It doesn't matter too much which one you choose here, but here is a [nice article](https://www.redhat.com/sysadmin/podman-compose-docker-compose) comparing the two.

### Podman

The version of Podman in Debian's default `apt` repositories is super out of date.
We'll first add the Alvistacks repository to get a fresher release:

```bash
source  /etc/os-release
wget http://downloadcontent.opensuse.org/repositories/home:/alvistack/Debian_$VERSION_ID/Release.key -O alvistack_key
cat alvistack_key | gpg --dearmor | sudo tee /etc/apt/trusted.gpg.d/alvistack.gpg  >/dev/null
rm alvistack_key
echo "deb http://downloadcontent.opensuse.org/repositories/home:/alvistack/Debian_$VERSION_ID/ /" | sudo tee  /etc/apt/sources.list.d/alvistack.list
```

Now we're ready to install everything we need:

```bash
sudo apt install podman passt netavark
```

You'll also need to enable the socket if you want Portainer or `docker-compose` to work.
If you want to make a user for this and you haven't yet, you can [skip ahead](#creating-a-user-with-subuids-and-subgids) and come back here.
Make sure to substitute the username and UID with those of the user you'll be using to run podman:

```bash
sudo -u podman-user XDG_RUNTIME_DIR=/run/user/2000 systemctl --user enable --now podman.socket
```

You should now see them all working together when you run `docker-compose --version` or `podman-compose --version`.
Check the versions for `podman` and `docker-compose` or `podman-compose`,
and compare to the most recent releases their respective Github repositories.
They shouldn't be far behind.

### Podman Compose

If you want to install `podman-compose`, I would recommend using `pipx`:

```bash
sudo apt install pipx
sudo pipx install --global podman-compose
```

### Docker Compose

The version of `docker-compose-plugin` in the default debian `apt` repositories is also very outdated (v1.something).
To fix this, we're going to get a more recent version of `docker-compose-plugin` from the official docker repository.
First we follow the [official instructions](https://docs.docker.com/engine/install/debian/#install-using-the-repository) from docker to add the Docker apt repository:

```bash
# Add Docker's official GPG key:
sudo apt-get update
sudo apt-get install ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

# Add the repository to Apt sources:
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update
```

Then, you can install docker-compose using `apt`.
It won't be available in your `$PATH` by default but you can create a symlink:

```bash
sudo apt install docker-compose-plugin 
sudo ln -s /usr/libexec/docker/cli-plugins/docker-compose /usr/local/bin/docker-compose
```

You'll also need to have `DOCKER_HOST` set to the correct socket to redirect docker-compose to podman.
You can add this to your user's `~/.profile` or `~/.bashrc`, or do it manually before using `docker-compose`:

```bash
export DOCKER_HOST=unix:///var/run/user/2000/podman/podman.sock
```

## Allowing Binding to Privileged Ports

By default, most linux distros will only allow processes running as root to bind to ports lower than 1024.
The easiest solution would be to simply use `sysctl net.ipv4.ip_unprivileged_port_start` to lower this number to something like 53.
However this leaves a sour taste in my mouth, as this would allow any process on the machine to bind to any port above 52.
There are a few alternative solutions as discussed [here](https://linuxconfig.org/how-to-bind-a-rootless-container-to-a-privileged-port-on-linux).

The solution I use involves binding the containers to unprivileged ports and using port forwarding with UFW.
I just add 10000 to any of the ports I need to bind (e.g. binding Pi-Hole to port 10053),
and forward incoming connections on the default ports to the container port.
This will need to be done with `iptables`, but since it's not persistent we can add the rules to our UFW instead.
The process is basically the same as described [here](https://www.baeldung.com/linux/ufw-port-forward),
but modified for 3 ports and copied for IPv6 support.

Add the following to the bottom of your `/etc/ufw/before.rules` using an editor of your choice (I used `nano`):

```
# NAT table rules
*nat
:POSTROUTING ACCEPT [0:0]

# Forward DNS traffic from port 10053 to port 53 (UDP only)
-A PREROUTING -p udp --dport 53 -j REDIRECT --to-port 10053

# Forward DNS traffic from port 10053 to port 53 (TCP only)
-A PREROUTING -p tcp --dport 53 -j REDIRECT --to-port 10053

# Forward HTTPS traffic from port 10443 to port 443 (TCP only)
-A PREROUTING -p tcp --dport 443 -j REDIRECT --to-port 10443

# Forward SMB traffic from port 10445 to port 445 (TCP only)
-A PREROUTING -p tcp --dport 445 -j REDIRECT --to-port 10445

# Don’t masquerade local traffic.
-A POSTROUTING -s 192.168.1.0/24 -j MASQUERADE

COMMIT
```

Similarly, insert the following at the end of your `/etc/ufw/before6.rules`

```
# NAT table rules
*nat
:POSTROUTING ACCEPT [0:0]

# Forward DNS traffic from port 10053 to port 53 (UDP only)
-A PREROUTING -p udp --dport 53 -j REDIRECT --to-port 10053

# Forward DNS traffic from port 10053 to port 53 (TCP only)
-A PREROUTING -p tcp --dport 53 -j REDIRECT --to-port 10053

# Forward HTTPS traffic from port 10443 to port 443 (TCP only)
-A PREROUTING -p tcp --dport 443 -j REDIRECT --to-port 10443

# Forward SMB traffic from port 10445 to port 445 (TCP only)
-A PREROUTING -p tcp --dport 445 -j REDIRECT --to-port 10445

COMMIT
```

Since these are `PREROUTING` rules, the port forwarding will occur *before* the traffic hits your UFW rules.
As a result, the UFW rules used in [the firewall configuration](./scripts/configure-ufw.sh) use the unprivileged ports instead.

**Note** - This also has the effect that your services will not be accessible when your UFW is disabled.
I don't mind this trade-off personally since I never planned to turn it off anyway, but keep in mind.

## Fixing Podman's Hostname Resolution (Optional)

You may also run into the following problem, even if you port forward DNS to an alternate port as described above.
Podman uses a DNS server to allow for our containers to resolve each other's hostnames.
Trying to host our Pi-Hole on port 53 (the default DNS port) causes a clash between these two systems.
This results in our containers being unable to find each other unless they're fed a list of static IPs, which would be kinda lame.

To fix this, we'll make a small change to `/usr/share/containers/containers.conf`.
Find the following block under `[network]`, uncomment the last line and change the default `dns_bind_port` to something such as `1053`:

```
# Port to use for dns forwarding daemon with netavark in rootful bridge
# mode and dns enabled.
# Using an alternate port might be useful if other dns services should
# run on the machine.
#
dns_bind_port = 1053
```

I'd recommend doing this regardless, even if you're port forwarding, when you're hosting DNS.
Although it says it's used for rootful mode networking, this fixes our rootless networking problem too.
Sidenote - it would be just great if this caveat was mentioned literally anywhere, it took me so long to figure this out.

# Podman & Volume Permissions - A Match Made in Hell

As Docker users, sometimes we take for granted that you mount volumes and it actually Just Works™.
Unfortunately, we can't have nice things with Podman due to the user namespace permissions.

## The Issue

So the problem goes like this - There are (roughly speaking) 3 different types of volumes we need to mount:

1. Our media files, such as movies, documents, etc.
2. Our services' configuration files
3. Other system stuff, such as our `podman.socket` and `/etc/localtime`

Next, there are 2 different users on the host that need to be able to access these files:

1. Our personal user(s) - These guys only realistically need access to our media, but can probably use `sudo` to modify configurations if/when necessary
2. Our container runner - This is the separate user we made to run podman, and it will need access to everything

Finally, and this is the worst part, there are several different container users that need access to these files:

- Most containers allow you to choose what user/UID is used to run the service
  - The lscr.io/linuxserver/ containers (most of the *arr suite) allow configuration using the $PUID and $PGID environment variables.
  These ones will initially start as root, potentially modify some files as root, drop down to the specified user, and probably modify files some more (just great)
  - Some containers have native support for starting as a specified user by passing `--user <SOME-UID>:<SOME-GID>` to Podman/Docker, and will only interact as that user.
  These are the only actually good ones in my opinion, but only a couple of the 20+ containers support this.

- Some containers will refuse to use anything other than the root user, some for good reasons (actually performing necessarily rootful operations), most for bad reasons (just blame the devs, idk ¯\\\_(ツ)\_/¯)
- Some containers are hard-coded to run as strange UIDs, and you're straight out of luck. To name and shame a few:
  - MongoDB and MariaDB both run as UID 999 and GID 999
  - Redis runs as UID 999 and GID 0 (wtf?)
  - Nextcloud runs as UID 33 and GID 33, but also has a Daemon running as UID 1 and GID 1???

As if it wasn't already enough of a nightmare, let me add a few extra hurdles:

1. If you use the `:U` flag with volumes for your rootless containers, it will `chown` them on the host to the subuid used in the container, and your regular users will lose access to the files. This also completely breaks sometimes if the service in the container changes user after starting, as podman has no way of figuring out what user to mount the files for.
2. You can't use `--userns` or `--uidmap` when your pods are all in a pod (yes that sentence is confusing, but I digress)
3. You also can't use idmapped mounts (i.e. using the `:idmap=...` flag) when using `podman-compose`.

At this point I was conflicted between either braiding my now-grey hairs into a noose, flying to Japan to commit Seppuku, or taking a bath with my favourite toaster.
But alas, there is light at the end of the tunnel

## The Solution

First, we forego using the `:U` volume flag altogether.
Mot only do your regular users on the host lose access to your files if the container runs as anything but root (with the standard `--userns=host` at least), but if multiple containers want to share the same files, they'll also need matching UIDs/GIDs, which isn't possible thanks to various random hard-coded users.

We can also get rid of the incapsulating Pod as well, we already have a custom network that our pods can use to communicate so we can use hostname resolution instead of localhost.
This also allows services with clashing non-configurable ports to get their own interfaces, and lets us have different user namespaces for each pod.
Podman compose allows us to do this with the `x-podman` key, as documented [here](https://github.com/containers/podman-compose/blob/main/docs/Extensions.md#custom-pods-management).

Now that we have access to `--userns`, the plan goes like this:

1. On the host, `chown` all of our files to that our `podman-user` is the owner of all our media and config files.
We can also get away with only giving `podman-user` access through the group, in cases where you want your primary user to own the files.
2. For each of the containers, we use a custom user namespace where the `podman-user` outside the container maps to the specific UID/GID in the container that is interacting with our files.

For the containers that we can configure to run as `$PUID:$PGID`, we use `--userns=keep-id:uid=${PUID},gid=${PGID}`, which covers:

- Jellyfin
- Jellyseerr
- Sonarr
- Radarr
- Lidarr
- Readarr
- Bazarr
- Prowlarr
- Flaresolverr
- Pi-Hole
- Homepage
- Code-Server

For containers that run as root, we map our user on the host to be root in the container with `--userns=host`.
This covers:

- Kapowarr
- Kavita
- Caddy
- Portainer
  - It also requires `--security_opt no-new-privileges:false`, and `--security_opt label:disable` with SELinux
  - This is a recipe for disaster icl, if I was red-teaming this would definitely pique my interest
- Overleaf

This leaves only the containers that are hard-coded to run as certain UIDs:

- Mariadb needs `--userns=keep-id:uid=999,gid=999`
- MongoDB needs `--userns=keep-id:uid=999,gid=999`
- Redis needs `--userns=keep-id:uid=999,gid=0`
- Nextcloud needs `--userns=keep-id:uid=33,gid=33`
- Unbound needs `--userns=keep-id:uid=1000,gid=1000`
- qBittorrent needs `--userns=keep-id:uid=1000,gid=1000` (used to be configurable before the 5.0.0 update)

This is a fair bit of overhead since we have a namespace for each container instead of just one for the overarching Pod, but even this solution took me a week to figure out, and I can't see any other way.

# Installation

I'll make a proper installer if enough people care about this, but until then, it's mostly manual.

## Creating a User with SubUIDs and SubGIDs

It's good practice to create a dedicated user for running this stuff.
First, we'll create a new user with some subordinate mappings to run our containers.
You can pick any valid username, UID, GID, SubUIDs and SubGIDs you want:

```
sudo groupadd -g 2000 podman-group
sudo adduser --uid 2000 --gid 2000 --comment "Podman Services Runner" --home /home/podman-user podman-user
sudo usermod --add-subuids 200000-265535 --add-subgids 200000-265535 podman-user
sudo loginctl enable-linger podman-user
```

You can optionally add your own user to the new group here if you want to, which will give you access to files owned by podman-user:

```
sudo usermod -aG podman-group <YOUR_USER>
```

## Configuring the Services

Before running the installer, customise the `.env` file.
All the variables should be set, but some have sensible defaults already.

| Variable                                  | Purpose                                                                                                                                                     |
|-------------------------------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------|
| SOCKET_PATH                               | Path to Podman API socket of user running the containers                                                                                                    |
| CONFIG_DIRECTORY                          | Parent folder for container configuration directories                                                                                                       |
| MEDIA_DIRECTORY                           | Folder to store media (must contain the subdirectories `movies`, `tvshows`, `music`, `ebooks`)                                                              |
| PUID and PGID                             | User within the container to run services under ([not supported by all containers](#the-solution))                                                          |
| PRIVATE_USER_UID                          | Samba's private user's UID ([see official docs](https://github.com/ServerContainers/samba?tab=readme-ov-file#environment-variables-and-defaults))           |
| PRIVATE_USER_HASH                         | Samba's private user's password hash ([see official docs](https://github.com/ServerContainers/samba?tab=readme-ov-file#environment-variables-and-defaults)) |
| PRIVATE_SHARE_PATH and  PUBLIC_SHARE_PATH | Directories to be used as root folder of SMB shares                                                                                                         |
| NEXTCLOUD_DATA_DIRECTORY                  | Directory for Nextcloud's user's files will be stored (images, history, etc., the main document goes into the database)                                     |
| PRIVATE_DOWNLOADS_DIRECTORY               | Where the private qBittorrent instance downloads files                                                                                                      |
| MARIADB_PASSWORD                          | Password for connecting to MariaDB database (used by Nextcloud)                                                                                             |
| REDIS_NEXTCLOUD_PASSWORD                  | Password for connecting to Redis (used by Nextcloud)                                                                                                        |
| REDIS_OVERLEAF_PASSWORD                   | Password for connecting to Redis (used by Overleaf)                                                                                                         |
| CODE_PASSWORD                             | Web GUI password for connecting to Code Server                                                                                                              |
| CODE_SUDO_PASSWORD                        | Sudo password for elevating privileges in integrated terminal                                                                                               |
| IPV4_SUBNET                               | IPv4 Subnet used for custom network                                                                                                                         |
| PIHOLE_IPV4                               | Static IPv4 address for Pi-Hole in custom network                                                                                                           |
| UNBOUND_IPV4                              | Static IPv4 address for Unbound in custom network                                                                                                           |
| IPV6_SUBNET                               | IPv6 Subnet used for custom network                                                                                                                         |
| PIHOLE_IPV6                               | Static IPv6 address for Pi-Hole in custom network                                                                                                           |
| UNBOUND_IPV6                              | Static IPv4 address for Unbound in custom network                                                                                                           |

You should also edit the services in the `services/` folder 
You should also edit [the pihole custom list](./config/pihole/custom.list) with any names you want your server to respond on

## Running The media-server.sh installer

The [media-server.sh](./scripts/media-server.sh) script has a few functions to help automate starting, stopping, and installing the media services.

In particular, the installer in it automates a few basic tasks, including:

- Creating a symlink to the script in your `$PATH`
- Adding firewall rules to allow LAN access to the services
- Installing and enabling the podman socket for the user running the containers
- Installing and enabling the media server services
- Creates empty config folders (since podman doesn't autocreate non-existent bind volumes)

To run the installer, do:

```bash
sudo ./scripts/media-server.sh install
```

The services won't be visible through your current user (unless you didn't create a dedicated user) as they're running with rootless podman under the new user.

You can check them with `sudo su -c "media-server ls all" podman-user`

# Post-Installation

After all the services are running, some manual configuration is required to get them all working together.
Plenty of guides on how to do this have been written in the past, so I'll just link each guide and add some extra notes where necessary.

I started with the simpler resources from [YAMS](https://yams.media/config/bazarr/) (the predecessor of this media server).
but it doesn't cover all of the services that are hosted.

[TRaSH Guides](https://trash-guides.info/) has great resources for more detailed configurations, and covers more services.

I found that using Jellyfin's web interface with Firefox causes it to transcode a lot of videos,
which turned out to be due to [Firefox's codec support](https://jellyfin.org/docs/general/clients/codec-support/).
However, the Desktop app also doesn't work out of the box due to Caddy's self-signed certificates being untrusted. 

To fix this, you can modify the app's config file, which is usually at `%LocalAppData%JellyfinMediaPlayer\jellyfinmediaplayer.conf` and change the following variable to true:

```
{
    "sections": {
        ...
        "main": {
            ...
            "ignoreSSLErrors": true,
...
```

# Uninstallation

To uninstall, you'll need to go through the installation in reverse.
First, the script also contains an uninstaller that reverses the changes it makes, and can be run with:

```bash
sudo ./scripts/media-server.sh uninstall
```

This will take care of:

- Disabling the systemd services
- Deleting the containers
- Deleting symlinks for scripts that were added
- Removing the UFW `allow` rules

You'll need to remove the port-forwarding rules you added to `/etc/ufw/before.rules` and `/etc/ufw/before6.rules` manually.
Running `ufw reset` will do this for you if you don't care about existing rules.

Finally you can delete the user you created and uninstall any packages you installed earlier, but that's optional.

# Using Docker with UFW

If you did decide to go with Docker instead (completely understandable),
you'll also need to make a few adjustments to make sure it doesn't completely ignore your firewall rules.
The issue is pretty well documented in [this repository](https://github.com/chaifeng/ufw-docker).
It gives the choice of using either the `ufw-user-forward` or `ufw-user-input`, and gives the pros/cons for both.
Personally I prefer `ufw-user-input`, so I'll explain how to do it with that.

Add the following to your `/etc/ufw/after.rules`:

```
# BEGIN UFW AND DOCKER
*filter
:ufw-user-input - [0:0]
:DOCKER-USER - [0:0]

# Process user rules first
-A DOCKER-USER -j ufw-user-input

# Automatically allow internal networks
# -A DOCKER-USER -j RETURN -s 10.0.0.0/8
# -A DOCKER-USER -j RETURN -s 172.16.0.0/12
# -A DOCKER-USER -j RETURN -s 192.168.0.0/16

# Allow DNS
-A DOCKER-USER -p udp -m udp --sport 53 --dport 1024:65535 -j RETURN

# Allow outgoing traffic
-A DOCKER-USER -j DROP -p tcp -m tcp --tcp-flags FIN,SYN,RST,ACK SYN -d 192.168.0.0/16
-A DOCKER-USER -j DROP -p tcp -m tcp --tcp-flags FIN,SYN,RST,ACK SYN -d 10.0.0.0/8
-A DOCKER-USER -j DROP -p tcp -m tcp --tcp-flags FIN,SYN,RST,ACK SYN -d 172.16.0.0/12
-A DOCKER-USER -j DROP -p udp -m udp --dport 0:32767 -d 192.168.0.0/16
-A DOCKER-USER -j DROP -p udp -m udp --dport 0:32767 -d 10.0.0.0/8
-A DOCKER-USER -j DROP -p udp -m udp --dport 0:32767 -d 172.16.0.0/12

-A DOCKER-USER -j RETURN

COMMIT
# END UFW AND DOCKER
```

And similarly, add this to `/etc/ufw/after6.rules` if you want IPv6 filtering too:

```
# BEGIN UFW AND DOCKER
*filter
:ufw6-user-input - [0:0]
:DOCKER-USER - [0:0]

# Process user rules first
-A DOCKER-USER -j ufw6-user-input

# Automatically allow internal networks
# -A DOCKER-USER -j RETURN -s fc00::/7
# -A DOCKER-USER -j RETURN -s fe80::/10

# DNS
-A DOCKER-USER -p udp -m udp --sport 53 --dport 1024:65535 -j RETURN

# ALLOW OUTGOING
-A DOCKER-USER -j DROP -p tcp -m tcp --tcp-flags FIN,SYN,RST,ACK SYN -d fc00::/7
-A DOCKER-USER -j DROP -p tcp -m tcp --tcp-flags FIN,SYN,RST,ACK SYN -d fe80::/10
-A DOCKER-USER -j DROP -p udp -m udp --dport 0:32767 -d fc00::/7
-A DOCKER-USER -j DROP -p udp -m udp --dport 0:32767 -d fe80::/10

-A DOCKER-USER -j RETURN

COMMIT
# END UFW AND DOCKER
```

You can choose whether or not to uncomment the blocks that automatically allow internal networks.
I personally like to add UFW rules for them manually, I don't like secret allow rules that don't show up in `ufw status`.

Finally, you may also encounter an issue where UFW silently fails to clean up your chains properly on shutdown,
causing problems with later interactions with UFW or iptables.
The solution is mentioned [here](https://unix.stackexchange.com/questions/617240/ufw-iptables-jump-rule-errors-with-could-not-load-logging-rules).
Add the following to the `stop)` clause of your `/etc/ufw/before.init`:

```
stop)
    iptables -F ufw_user_input || true
    ip6tables -F ufw6_user_input || true
```