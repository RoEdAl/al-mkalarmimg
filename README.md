# mkalarmimg - simple script to create Arch Linux ARM images

Tested on Arch Linux.
Intended to invoke by `sudo`.

## Required packages

* `binfmt-support` (AUR)
* `qemu-user-static` (AUR)
* `wget`

## Usage

`sudo ./mkalarmimg.sh <config-file>`

For example:

`sudo ./mkalarmimg.sh a10-olinuxino-lime`

creates `alarm-a10-olinuxino-lime-XXXXXXXXXXXX.img.tar.xz` file.

### Additional parameters:

* `-s` - image size (1536M by default)
* `-p` - directory with additional packages
