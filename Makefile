SHELL = /bin/sh

.PHONY: all
all: firmware kernel_image

.PHONY: toolchain
toolchain: thunderx-tools-97
thunderx-tools-97:
	wget http://dev.gateworks.com/sources/tools-gcc-6.2.tar.bz2
	tar xvf tools-gcc-6.2.tar.bz2

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

LINUXPARTSZ ?= 7248M
.PHONY: firmware-image
firmware-image: firmware jtag_image
	$(MAKE) version
	# generate our own bdk.bin with different contents/offsets
	./newport/bdk-create-fatfs-image.py create \
		--partsize $(LINUXPARTSZ) \
		--out bdk.bin \
		--ap_bl1 bdk/apps/boot/boot.bin \
		--key bdk/trust-keys/hw-rot-private.pem \
		--nv 0   \
		bdk/apps/init/init.bin \
		bdk/apps/init/init.bin.sign \
		bdk/apps/setup/setup.bin.lzma \
		bdk/apps/setup/setup.bin.lzma.sign \
		bdk/trust-keys/bdk-sign.pub \
		bdk/trust-keys/bdk-sign.pub.sign \
		bdk/boards/gw*.dtb* \
		dts/gw*.dtb
	./newport/make-bootfs.py \
		--bs bdk.bin \
		--bl1 atf/build/t81/release/bl1.bin \
		--fip fip.img \
		-f firmware-newport.img
	./mkimage_jtag --emmc -e --partconf=user firmware-newport.img@user:erase_all:0-16M > firmware-newport.bin
ifdef ALLOW_DIAGNOSTICS
	# inject diagnostics
	fatfs-tool -i firmware-newport.img cp \
		bdk/apps/diagnostics/diagnostics.bin.lzma /
	fatfs-tool -i firmware-newport.img cp \
		bdk/apps/diagnostics/diagnostics.bin.lzma.sign /
endif
	# inject version info
	fatfs-tool -i firmware-newport.img cp version /
	# configure U-Boot env
	truncate -s 16M firmware-newport.img
	dd if=/dev/zero of=firmware-newport.img bs=1k seek=16320 count=64
	fw_setenv --config newport/fw_env.config --script newport/newport.env

.PHONY: bdk
bdk: toolchain
	$(MAKE) -C bdk
	[ -d bin ] || mkdir bin
	ln -sf ../bdk/utils/fatfs-tool/fatfs-tool bin/

.PHONY: uboot
uboot: toolchain
	$(MAKE) -C u-boot thunderx_81xx_defconfig u-boot-nodtb.bin
	$(MAKE) CROSS_COMPILE= -C u-boot env
	ln -sf ../u-boot/tools/mkimage bin/mkimage
	ln -sf ../u-boot/tools/env/fw_printenv bin/fw_printenv
	ln -sf ../u-boot/tools/env/fw_printenv bin/fw_setenv

.PHONY: atf
atf: toolchain
	$(MAKE) -C atf PLAT=t81 BL33=/dev/null SPD=none bl1
	$(MAKE) -C atf PLAT=t81 BL33=/dev/null SPD=none fip
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
	$(MAKE) linux
	rm -rf linux/install
	mkdir -p linux/install/boot
	cp linux/arch/arm64/boot/Image linux/install/boot
	make -C linux INSTALL_MOD_PATH=install modules_install
	tar -cvJf linux-newport.tar.xz --numeric-owner -C linux/install .

.PHONY: uboot-fip
uboot-fip: uboot
	$(MAKE) atf
	cp atf/build/t81/release/fip.bin fip.img
	fiptool update --nt-fw u-boot/u-boot-nodtb.bin fip.img

.PHONY: dts
dts:
	make -C dts
	fatfs-tool -i bdk/target-bin/bdk.bin cp dts/gw*.dtb /

UBUNTU_FSSZMB ?= 1536M
UBUNTU_REL ?=  bionic
UBUNTU_KERNEL ?= linux/arch/arm64/boot/Image
UBUNTU_FS ?= $(UBUNTU_REL)-arm64.ext4
UBUNTU_IMG ?= $(UBUNTU_REL)-newport.img
UBUNTU_ROOTFS ?= $(UBUNTU_REL)-arm64.tar.xz

$(UBUNTU_FS): kernel_image
	wget -N http://dev.gateworks.com/ubuntu/$(UBUNTU_REL)/$(UBUNTU_ROOTFS)
	sudo ./newport/mkfs ext4 $(UBUNTU_FS) $(UBUNTU_FSSZMB) linux-newport.tar.xz $(UBUNTU_ROOTFS)

.PHONY: ubuntu-image
ubuntu-image: $(UBUNTU_FS) firmware-image kernel_image
	cp firmware-newport.img $(UBUNTU_IMG)
	# create kernel.itb with compressed kernel image
	cp $(UBUNTU_KERNEL) vmlinux
	gzip -f vmlinux
	./newport/mkits.sh -o kernel.its -k vmlinux.gz -C gzip -v "Ubuntu"
	mkimage -f kernel.its kernel.itb
	# inject kernel.itb into FATFS
	fatfs-tool -i $(UBUNTU_IMG) cp kernel.itb /
	# inject bootscript into FATFS
	mkimage -A arm64 -T script -C none -d newport/ubuntu.scr ./newport.scr
	fatfs-tool -i $(UBUNTU_IMG) cp newport.scr /
	# copy ubuntu rootfs to image
	dd if=$(UBUNTU_FS) of=$(UBUNTU_IMG) bs=16M seek=1
	# compress it
	gzip -k -f $(UBUNTU_IMG)

.PHONY: openwrt
openwrt:
	if [ -d "openwrt/feeds" ]; then \
		$(MAKE) -C openwrt; \
	else \
		$(MAKE) -C openwrt/gateworks octeontx; \
	fi

OPENWRT_DIR ?= openwrt/bin/targets/octeontx/generic/
OPENWRT_FS ?= $(OPENWRT_DIR)openwrt-octeontx-squashfs.img
OPENWRT_KERNEL ?= $(OPENWRT_DIR)openwrt-octeontx-vmlinux
OPENWRT_IMG ?= openwrt-newport.img
.PHONY: openwrt-image
openwrt-image: firmware-image openwrt
	cp firmware-newport.img $(OPENWRT_IMG)
	# create kernel.itb with compressed kernel image
	cp $(OPENWRT_KERNEL) vmlinux
	gzip -f vmlinux
	./newport/mkits.sh -o kernel.its -k vmlinux.gz -C gzip -v "OpenWrt"
	mkimage -f kernel.its kernel.itb
	# inject kernel.itb into FATFS
	fatfs-tool -i $(OPENWRT_IMG) cp kernel.itb /
	# inject bootscript into FATFS
	mkimage -A arm64 -T script -C none -d newport/openwrt.scr ./newport.scr
	fatfs-tool -i $(OPENWRT_IMG) cp newport.scr /
	# copy openwrt rootfs to image
	dd if=$(OPENWRT_FS) of=$(OPENWRT_IMG) bs=16M seek=1
	# compress it
	gzip -k -f $(OPENWRT_IMG)

.PHONY: clean
clean: clean-firmware clean-linux
	rm -f version kernel.itb kernel.its vmlinux vmlinux.gz

.PHONY: clean-linux
clean-linux:
	make -C linux clean

.PHONY: clean-firmware
clean-firmware: clean-bdk clean-atf clean-uboot
	rm -f firmware-newport.img firmware-newport.bin mkimage_jtag fip.img

.PHONY: clean-bdk
clean-bdk:
	make -C bdk clean

.PHONY: clean-atf
clean-atf:
	make -C atf PLAT=t81 BL33=/dev/null SPD=none clean

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
	make -C dts distclean
	make -C openwrt distclean
