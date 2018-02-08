#!/bin/bash -e

declare -r APPTITLE=mkalarmimg

declare PKGDIR='/home/builder/mkpkg/pkg'
declare IMGSIZE=1536M
declare CFNAME
declare DOWNLOAD_APKG=0

# --------------------------------------------

function die() {
	printf "$1\n" "${@:2}"
	exit 1
}

function log_msg {
    logger -s -t ${APPTITLE} "$@"
}

function show_usage() {
    echo "Usage: ${0/*\//} [-s <imgsize> ] [ -p <pkgdir> ] [-d] <configuration-file>"
}

function user_wget() {
	if [[ ${SUDO_USER} ]]; then
		runuser -m --user=${SUDO_USER} -- wget "$@"
	else
		wget "$@"
	fi
}

function find_pkg {
  ls -v ${1}-*-*-${Arch}.pkg.*
}

function find_pkgs() {
  local -a PKGS
  for PKG in "${LocalPkgs[@]}"; do
    PKGS+=( $(cd "${PKGDIR}"; find_pkg "${PKG}") )
  done

  echo "${PKGS[@]}"
}

function get_kernel_pkg_name {
   case ${Arch} in
       aarch64) echo 'linux-aarch64';;
       armv7h) echo 'linux-armv7';;
       *) return 1;;
   esac
}

function get_rc_kernel_pkg_name {
   case ${Arch} in
       aarch64) echo 'linux-aarch64-rc';;
       armv7h) echo 'linux-armv7-rc';;
       *) return 1;;
   esac
}

function get_qemu_static {
   case ${Arch} in
       aarch64) echo 'qemu-aarch64-static';;
       armv7h) echo 'qemu-arm-static';;
       *) return 1;;
   esac
}

function get_alarm_package_name {
   case ${Arch} in
       aarch64) echo 'ArchLinuxARM-aarch64-latest';;
       armv7h) echo 'ArchLinuxARM-armv7-latest';;
       *) return 1;;
   esac
}

function alarm_nspawn {
	local IMGFILE=$1
	shift
	local MNAME=$1
	shift
	local EXCHANGE_DIR=$1
	shift
	systemd-nspawn --quiet \
		-i ${IMGFILE} -M ${MNAME} \
		--as-pid2 \
		-E 'PREPARING_IMAGE=1' \
		-E 'SYSTEMD_OFFLINE=on' \
		--link-journal=no \
		--bind-ro=/usr/bin/$(get_qemu_static) \
		--bind-ro=/run/systemd/journal/dev-log:/dev/log \
		--bind-ro=/run/systemd/resolve/stub-resolv.conf:/etc/resolv.conf \
		--bind-ro=${PKGDIR}:/root/install/pkg \
		--tmpfs=/root/install/cache \
		--bind=${EXCHANGE_DIR}:/root/install/exchange \
		-u root \
		"$@"
}

function prepare_exchange_dir {
	local EXCHANGE_DIR=$1
	shift

	local -a PACKAGES
	PACKAGES=("$@")
	(cat <<EOF

# additional packages at /usr/share/pkgs
[local-pkgs]
Server=file:///usr/share/pkgs
SigLevel=Optional
EOF
	) >> ${EXCHANGE_DIR}/custom-repo.txt

	(cat <<'EOF'
#!/bin/bash -e
declare -r APPTITLE=mkalarmimg

function log_msg {
    logger -s -t v-${APPTITLE} "$@"
}
EOF
	cat <<EOF

log_msg 'pacman, log to syslog/journal only'
sed -i '/LogFile/ a LogFile=/dev/null' /etc/pacman.conf
sed -i '/UseSyslog/s/^#//g' /etc/pacman.conf

log_msg 'create local package repository'
mkdir -m0644 -p /usr/share/pkgs
for PKG in ${PACKAGES[@]}; do
EOF
	cat <<'EOF'
	cp /root/install/pkg/${PKG} /usr/share/pkgs
EOF
	cat <<EOF
done
repo-add -q /usr/share/pkgs/local-pkgs.db.tar ${PACKAGES[@]/#//usr/share/pkgs/}
cat /root/install/exchange/custom-repo.txt >> /etc/pacman.conf

log_msg 'manage packets'
pacman --cachedir=/root/install/cache --noconfirm -Rs man-db man-pages
pacman --cachedir=/root/install/cache --noconfirm -Syyu ${InstallPkgs[*]}

log_msg 'clean cache'
echo -e 'y\ny\n' | pacman -Scc

log_msg 'remove .pacnew files from /etc'
rm /etc/*.pacnew || true

log_msg "tmpfs as alarm's home directory"
echo '# home directory to alarm user' >> /etc/fstab
echo 'tmpfs /tmp/alarm tmpfs rw,nodev,size=25%,uid=1000,gid=1000,noauto,x-systemd.automount,user,mode=0700 0 0' >> /etc/fstab
echo '' >> /etc/fstab
usermod -d /tmp/alarm alarm
rm -rf /home/alarm

log_msg 'make /var/log volatile directory'
rm -rf /var/log/*
echo '# /var/log - volatile directory' >> /etc/fstab
echo 'tmpfs /var/log tmpfs rw,nodev,nosuid,noexec,nodev,relatime,size=32M,nr_inodes=1k 0 0' >> /etc/fstab

log_msg 'journal configuration, volatile storage'
mkdir -m 0755 -p /usr/lib/systemd/journald.conf.d
cp /root/install/exchange/volatile-storage.conf /usr/lib/systemd/journald.conf.d/

log_msg 'copy bootloader outside'
if [[ -e /boot/u-boot-sunxi-with-spl.bin ]]; then
  cp /boot/u-boot-sunxi-with-spl.bin /root/install/exchange
fi

log_msg 'systemd, set default target'
systemctl set-default multi-user.target |& log_msg

log_msg 'done'
EOF
	) >> ${EXCHANGE_DIR}/manage-packets.sh
	chmod +x ${EXCHANGE_DIR}/manage-packets.sh

	(cat <<EOF
[Journal]
Storage=volatile
EOF
	) >> ${EXCHANGE_DIR}/volatile-storage.conf
	chmod 0644 ${EXCHANGE_DIR}/volatile-storage.conf
}

# ----------------------------------------------------

if [ $# -lt 1 ]; then
    show_usage
    exit 1
fi

while getopts ":s:p:dh" OPT; do
  case $OPT in
    s)
      IMGSIZE=$OPTARG
      ;;
    p)
      PKGDIR=$OPTARG
      ;;
    d)
      DOWNLOAD_APKG=1
      ;;
    h)
      show_usage
      exit 1
      ;;
    :)
      die '%s: option requires an argument -- '\''%s'\' "${0##*/}" "$OPTARG"
      ;;
    \?)
      die '%s: invalid option -- '\''%s'\' "${0##*/}" "$OPTARG"
      ;;
  esac
done
shift $((OPTIND-1))

CFNAME=$1
[[ $CFNAME ]] || die "%s: configuration file not specified" "${0##*/}"

# ----------------------------------------------------

. ${CFNAME}

declare -r ALARM_PACKAGE=$(get_alarm_package_name).tar.gz
declare -r ALARM_PACKAGE_MD5=${ALARM_PACKAGE}.md5

if (( ! DOWNLOAD_APKG )); then
        [ -f ${ALARM_PACKAGE} ] || {
                log_msg 'Download Arch Linux ARM package'
                user_wget http://os.archlinuxarm.org/os/${ALARM_PACKAGE}
        }

        [ -f ${ALARM_PACKAGE_MD5} ] || {
                log_msg 'Download Arch Linux ARM package MD5 checksum'
                user_wget http://os.archlinuxarm.org/os/${ALARM_PACKAGE_MD5}
        }
else
        [ -f ${ALARM_PACKAGE} ] && rm ${ALARM_PACKAGE}
        [ -f ${ALARM_PACKAGE_MD5} ] && rm ${ALARM_PACKAGE_MD5}

        log_msg 'Download Arch Linux ARM package'
        user_wget http://os.archlinuxarm.org/os/${ALARM_PACKAGE}

        log_msg 'Download Arch Linux ARM package MD5 checksum'
        user_wget http://os.archlinuxarm.org/os/${ALARM_PACKAGE_MD5}
fi

log_msg 'check package checksum'
md5sum --quiet --check ${ALARM_PACKAGE_MD5}

declare -r TIMESTAMP=$(date --utc '+%Y%m%d%H%M')

log_msg 'create image file'
IMGFILE=$(mktemp -p $PWD ${APPTITLE}-XXXXXXXX.img)
truncate -s ${IMGSIZE} ${IMGFILE}
chmod 0644 ${IMGFILE}

log_msg 'create partition(s)'
echo ',,,*' | sfdisk --quiet $IMGFILE

log_msg 'prepare loop device'
LOOPDEV=$(losetup --find --partscan --show $IMGFILE)

log_msg 'format partition(s)'
mkfs.ext4 -q -O ^metadata_csum,^64bit -M nodiscard ${LOOPDEV}p1

log_msg 'mount root partition'
ROOTDIR=$(mktemp --tmpdir -d ${APPTITLE}-XXXXXXXX.d)
mount ${LOOPDEV}p1 ${ROOTDIR}

log_msg 'prepare root partiton'
bsdtar -xpf ${ALARM_PACKAGE} -C ${ROOTDIR}

log_msg 'unmount root partition'
umount ${ROOTDIR}
losetup -d ${LOOPDEV}
rm -rf ${ROOTDIR}

log_msg 'prepare scripts'
declare -r NMACHINE=$(uuidgen -r)
declare EXCHANGE_DIR=$(mktemp --tmpdir -d ${APPTITLE}-XXXXXXXX.d)
declare -a -r LOCAL_PKGS=( $(find_pkgs) )
prepare_exchange_dir ${EXCHANGE_DIR} "${LOCAL_PKGS[@]}"

log_msg 'execute scripts inside container'
alarm_nspawn ${IMGFILE} ${NMACHINE} ${EXCHANGE_DIR} /root/install/exchange/manage-packets.sh

if [[ -e ${EXCHANGE_DIR}/u-boot-sunxi-with-spl.bin ]]; then
	log_msg 'install bootloader'
	dd if=${EXCHANGE_DIR}/u-boot-sunxi-with-spl.bin of=${IMGFILE} bs=8k seek=1 conv=notrunc status=noxfer |& log_msg
else
	log_msg 'Bootloader not installed! Image will be unbootable.'
fi
rm -rf ${EXCHANGE_DIR}

declare -r IMGNAME=alarm-${CFNAME}-${TIMESTAMP}.img
log_msg 'create TAR package'
if [[ ${SUDO_USER} ]]; then
	runuser -m --user=${SUDO_USER} -- \
		tar --no-xattrs --no-acls --no-selinux \
			--transform="s,${IMGFILE:1},${IMGNAME}," \
			-v --show-transformed-names \
			-Scf ${IMGNAME}.tar ${IMGFILE} |& log_msg
	log_msg 'compress TAR package'
	runuser -m --user=${SUDO_USER} -- \
		xz -Ccrc32 -T0 -qz6 ${IMGNAME}.tar
else
	bsdtar --no-xattrs --no-fflags --no-acls -Scf ${IMGNAME}.tar ${IMGFILE}
	xz -Ccrc32 -T0 -qz6 ${IMGNAME}.tar
fi

log_msg 'clean up'
rm ${IMGFILE}

log_msg 'done'
