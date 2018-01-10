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
	make-bootfs.py --bs bdk/target-bin/bdk.bin --bl1 atf/build/t81/release/bl1.bin --fip fip.img -f firmware-newport.img
	fixpart firmware-newport.img

.PHONY: bdk
bdk: toolchain
	$(MAKE) -C bdk
	cp bdk/bin/fatfs-tool bin/

.PHONY: uboot
uboot: toolchain
	$(MAKE) -C u-boot thunderx_81xx_defconfig u-boot-nodtb.bin

.PHONY: atf
atf: toolchain
	$(MAKE) -C atf PLAT=t81 BL33=/dev/null SPD=none bl1
	$(MAKE) -C atf PLAT=t81 BL33=/dev/null SPD=none fip
	cp atf/tools/fiptool/fiptool bin/

.PHONY: linux
linux: toolchain
	$(MAKE) -C linux newport_defconfig all

.PHONY: kernel_image
kernel_image: toolchain
	$(MAKE) linux
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

.PHONY: clean
clean: clean-firmware clean-linux

.PHONY: clean-linux
clean-linux:
	make -C linux clean

.PHONY: clean-firmware
clean-firmware: clean-bdk clean-atf clean-uboot
	rm -f firmware-newport.img fip.img

.PHONY: clean-bdk
clean-bdk:
	make -C bdk clean

.PHONY: clean-atf
clean-atf:
	make -C atf clean

.PHONY: clean-uboot
clean-uboot:
	make -C u-boot clean

.PHONY: distclean
distclean: clean
	make -C u-boot distclean
	make -C atf distclean
	make -C bdk distclean
	make -C dts distclean
