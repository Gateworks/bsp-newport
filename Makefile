SHELL = /bin/sh

.PHONY: all
all: firmware kernel_image

.PHONY: toolchain
TOOLCHAIN ?= marvell-tools-238.0
toolchain: $(TOOLCHAIN)
$(TOOLCHAIN):
	wget http://dev.gateworks.com/sources/$(TOOLCHAIN).tar.bz2
	tar xvf $(TOOLCHAIN).tar.bz2

.PHONY: firmware
firmware:
	$(MAKE) bdk
	$(MAKE) atf
	$(MAKE) uboot-fip
	$(MAKE) dts

.PHONY: version
version:
	rm -f version
	@echo "BDK=$(shell awk -F\" '{print $$2}' bdk/libbdk-arch/bdk-version.c)" >> version
	@echo "ATF=$(shell strings atf/build/t81/release/bl1/build_message.o | sed -n '2p')" >> version
	@echo "UBOOT=$(shell cat u-boot/include/config/uboot.release)" >> version
	@echo "DTS=$(shell git -C dts describe --always --dirty)" >> version

.PHONY: jtag_image
jtag_image:
	wget -N http://dev.gateworks.com/jtag/mkimage_jtag
	chmod +x mkimage_jtag

%.dtb: %.dts
	$(MAKE) dts

%.sign: % bdk/trust-keys/bdk-sign-private.pem
	BDK_ROOT=bdk bdk/bin/bdk-sign bdk-sign-private $@ $<

%.lzma: %
	bdk/bin/lzma e $^ $@
	bdk/bin/bdk-aes-pad $@

atf/build/t81/release/bl1.bin: atf
bdk/target-bin/bl1.bin: atf/build/t81/release/bl1.bin
	cp atf/build/t81/release/bl1.bin bdk/target-bin/bl1.bin
	./newport/make-bootfs.py -s 1 --bl1 bdk/target-bin/bl1.bin -a --bootfs /dev/null

bdk/target-bin/bl1.bin.lzma.sign: bdk/target-bin/bl1.bin.lzma bdk/trust-keys/bdk-sign-private.pem
	BDK_ROOT=bdk bdk/bin/bdk-sign bdk-sign-private $@ $<

FATFS_START=1048576
FATFS_SIZE=13631488
LINUXPARTSZMB ?= 7248
NV_ARGS?=0
DTS_FILES=$(wildcard dts/*.dts)
DTB_FILES=$(DTS_FILES:%.dts=%.dtb)
DTB_SIGNATURES=$(DTS_FILES:%.dts=%.dtb.sign)
.PHONY: firmware-image
firmware-image: dts $(DTB_FILES) $(DTB_SIGNATURES) firmware jtag_image bdk/target-bin/bl1.bin.lzma.sign
	$(MAKE) version
	# generate our own bdk.bin with different contents/offsets
	FATFS_START=$(shell printf "0x%x" $(FATFS_START)) \
	FATFS_SIZE=$(shell printf "0x%x" $(FATFS_SIZE)) \
		./newport/bdk-create-fatfs-image.py create \
		--out bdk.bin \
		--ap_bl1 bdk/apps/boot/boot.bin \
		--key bdk/trust-keys/hw-rot-private.pem \
		--nv $(NV_ARGS) \
		bdk/apps/init/init.bin \
		bdk/apps/init/init.bin.sign \
		bdk/apps/setup/setup.bin.lzma \
		bdk/apps/setup/setup.bin.lzma.sign \
		bdk/trust-keys/bdk-sign.pub \
		bdk/trust-keys/bdk-sign.pub.sign \
		bdk/boards/gw*.dtb* \
		bdk/target-bin/bl1.bin.lzma \
		bdk/target-bin/bl1.bin.lzma.sign \
		$(DTB_FILES) \
		$(DTB_SIGNATURES)
	./newport/make-bootfs.py \
		--bs bdk.bin \
		--bl1 atf/build/t81/release/bl1.bin -a \
		--fip fip.img \
		-f firmware-newport.img
ifdef ALLOW_DIAGNOSTICS
	# inject diagnostics
	fatfs-tool -i firmware-newport.img cp \
		bdk/apps/diagnostics/diagnostics.bin.lzma /
	fatfs-tool -i firmware-newport.img cp \
		bdk/apps/diagnostics/diagnostics.bin.lzma.sign /
endif
	# inject version info
	fatfs-tool -i firmware-newport.img cp version /
ifdef USE_GPT
	# replace partition table with gpt
	$(eval TMP=$(shell mktemp -t tmp.XXXXXX))
	echo "creating new GPT in $(TMP)..."
	./newport/gptgen.py \
		--disk-size 16M \
		-p fatfs:fat16:$(FATFS_START):$(FATFS_SIZE) \
		-p atf:reserved:$$((0xe00000)):1024K \
		-p uboot:reserved:$$((0xf00000)):960K \
		-p env:reserved:$$((0xff0000)):64K \
		-p rootfs:linux:16M:$(LINUXPARTSZMB)M \
		--out $(TMP)
	# apply it to the image
	dd if=$(TMP) of=firmware-newport.img conv=notrunc
	rm $(TMP)
endif
	# configure U-Boot env
	truncate -s 16M firmware-newport.img
	dd if=/dev/zero of=firmware-newport.img bs=1k seek=16320 count=64
	fw_setenv --lock newport/. --config newport/fw_env.config --script newport/newport.env
	# extract and copy default firmware to 0x80000 for backup
	dd if=firmware-newport.img of=env bs=1k skip=16320 count=64
	dd if=env of=firmware-newport.img bs=1k seek=512 count=64 conv=notrunc
	# create jtag-able binary
	./mkimage_jtag --emmc -s --partconf=user firmware-newport.img@user:erase_part:0-32768 > firmware-newport.bin

ATF_NONSECURE_FLASH_ADDRESS ?= 0x00E00000
.PHONY: bdk
bdk: toolchain
	$(MAKE) -C bdk ATF_NONSECURE_FLASH_ADDRESS=$(ATF_NONSECURE_FLASH_ADDRESS)
	[ -d bin ] || mkdir bin
	ln -sf ../bdk/utils/fatfs-tool/fatfs-tool bin/

.PHONY: uboot
uboot: toolchain
	$(MAKE) -C u-boot newport_defconfig u-boot-nodtb.bin
	$(MAKE) CROSS_COMPILE= -C u-boot envtools
	ln -sf ../u-boot/tools/mkimage bin/mkimage
	ln -sf ../u-boot/tools/env/fw_printenv bin/fw_printenv
	ln -sf ../u-boot/tools/env/fw_printenv bin/fw_setenv

ATF_ARGS += PLAT=t81
ATF_ARGS += BL33=/dev/null
ATF_ARGS += SPD=none
ATF_ARGS += FIP_IMG_USER_LOC=1 FIP_IMG_FLASH_ADDRESS=0xF00000
.PHONY: atf
atf: toolchain
	$(MAKE) -C atf $(ATF_ARGS) bl1
	$(MAKE) -C atf $(ATF_ARGS) fip
	[ -d bin ] || mkdir bin
	ln -sf ../atf/tools/fiptool/fiptool bin/

.PHONY: linux
linux: toolchain
	$(MAKE) -C linux newport_defconfig all

.PHONY: kernel_menuconfig
kernel_menuconfig: toolchain
	$(MAKE) -C linux menuconfig
	$(MAKE) -C linux savedefconfig

.PHONY: kernel_image
kernel_image: toolchain
	# build
	$(MAKE) linux
	# install
	rm -rf linux/install
	mkdir -p linux/install/boot
	# install uncompressed kernel
	cp linux/arch/arm64/boot/Image linux/install/boot
	# also install a compressed kernel in a kernel.itb
	mkimage -f auto -A arm64 -O linux -T kernel -C gzip -n "Ubuntu" \
		-a $(LOADADDR) -e $(LOADADDR) -d linux/arch/arm64/boot/Image.gz kernel.itb
	# install kernel modules
	make -C linux INSTALL_MOD_STRIP=1 INSTALL_MOD_PATH=install modules_install
	make -C linux INSTALL_HDR_PATH=install/usr headers_install
	# cryptodev-linux build/install
	make -C cryptodev-linux KERNEL_DIR=../linux
	make -C cryptodev-linux KERNEL_DIR=../linux DESTDIR=../linux/install INSTALL_MOD_PATH=../linux/install install
	# newracom nrc7292 802.11ah driver
	make -C nrc7292/package/host/src/nrc/ KDIR=$(PWD)/linux modules
	make -C nrc7292/package/host/src/nrc/ KDIR=$(PWD)/linux \
		INSTALL_MOD_PATH=$(PWD)/linux/install modules_install
	# neramcom nrc7292 firmware
	mkdir -p linux/install/lib/firmware
	cp nrc7292/package/host/evk/sw_pkg/nrc_pkg/sw/firmware/nrc7292_* \
		linux/install/lib/firmware/
	# newracom nrc7292 cli app
	make -C nrc7292/package/host/src/cli_app/
	mkdir -p linux/install/usr/local/bin/
	cp nrc7292/package/host/src/cli_app/cli_app \
		linux/install/usr/local/bin/
	# FTDI USB-SPI driver
	make -C ftdi-usb-spi \
	KDIR=$(PWD)/linux INSTALL_MOD_PATH=$(PWD)/linux/install \
		INSTALL_MOD_STRIP=1 modules modules_install
	# tarball
	tar -cvJf linux-newport.tar.xz --numeric-owner --owner=0 --group=0 \
		-C linux/install .

.PHONY: uboot-fip
uboot-fip: uboot
	$(MAKE) atf
	cp atf/build/t81/release/fip.bin fip.img
	fiptool update --nt-fw u-boot/u-boot-nodtb.bin fip.img

.PHONY: dts
dts:
	make -C dts

UBUNTU_FSSZMB ?= 2048
UBUNTU_REL ?=  jammy
UBUNTU_KERNEL ?= linux/arch/arm64/boot/Image
UBUNTU_FS ?= $(UBUNTU_REL)-newport.ext4
UBUNTU_IMG ?= $(UBUNTU_REL)-newport.img
UBUNTU_ROOTFS ?= $(UBUNTU_REL)-newport.tar.xz

$(UBUNTU_FS): kernel_image
	wget -N http://dev.gateworks.com/ubuntu/$(UBUNTU_REL)/$(UBUNTU_ROOTFS)
	sudo ./newport/mkfs ext4 $(UBUNTU_FS) $(UBUNTU_FSSZMB)M \
		$(UBUNTU_ROOTFS) linux-newport.tar.xz

.PHONY: ubuntu-image
ubuntu-image: $(UBUNTU_FS) firmware-image kernel_image
	cp firmware-newport.img $(UBUNTU_IMG)
	# create kernel.itb with compressed kernel image
	cp $(UBUNTU_KERNEL) vmlinux
	gzip -f vmlinux
	mkimage -f auto -A arm64 -O linux -T kernel -C gzip -n "Ubuntu" \
		-a $(LOADADDR) -e $(LOADADDR) -d vmlinux.gz kernel.itb
	# create U-Boot bootscript
	mkimage -A arm64 -T script -C none -d newport/ubuntu.scr ./newport.scr
ifdef BOOTSCRIPT_IN_FATFS
	# inject kernel.itb into FATFS
	fatfs-tool -i $(UBUNTU_IMG) cp kernel.itb /
	# inject bootscript into FATFS
	fatfs-tool -i $(UBUNTU_IMG) cp newport.scr /
else
	$(eval TMP=$(shell mktemp -d -t tmp.XXXXXX))
	echo "using $(TMP)..."
	sudo mount $(UBUNTU_FS) $(TMP)
	sudo cp kernel.itb $(TMP)/boot/
	sudo cp newport.scr $(TMP)/boot/
	sudo umount $(TMP)
	sudo rmdir $(TMP)
endif
	# copy ubuntu rootfs to image
	dd if=$(UBUNTU_FS) of=$(UBUNTU_IMG) bs=16M seek=1
	# compress it
	gzip -k -f $(UBUNTU_IMG)

.PHONY: openwrt
openwrt:
	make -C openwrt/gateworks octeontx

.PHONY: openwrt-image
openwrt-image: firmware-image openwrt
	cp openwrt/bin/targets/octeontx/generic/gateworks-octeontx.img.gz \
		openwrt-newport.img.gz

.PHONY: clean
clean: clean-firmware clean-linux
	rm -f version kernel.itb kernel.its vmlinux vmlinux.gz

.PHONY: clean-linux
clean-linux:
	make -C linux clean
	rm -rf linux/install

.PHONY: clean-firmware
clean-firmware: clean-bdk clean-atf clean-uboot
	rm -f firmware-newport.img firmware-newport.bin mkimage_jtag fip.img

.PHONY: clean-bdk
clean-bdk:
	make -C bdk clean

.PHONY: clean-atf
clean-atf:
	make -C atf $(ATF_ARGS) clean

.PHONY: clean-uboot
clean-uboot:
	make -C u-boot clean

.PHONY: clean-openwrt
clean-openwrt:
	make -C openwrt clean

.PHONY: distclean
distclean: clean
	make -C u-boot distclean
	make -C atf distclean
	make -C bdk distclean
	make -C dts clean
	make -C openwrt distclean
