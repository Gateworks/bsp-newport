.PHONY: all
all: firmware

.PHONY: firmware
firmware: bdk uboot-fip dts
	./make-bootfs.py --bs bdk/target-bin/bdk.bin --bl1 atf/build/t81/release/bl1.bin --fip fip.img -f firmware-newport.img

.PHONY: bdk
bdk:
	make -j8 -C bdk

.PHONY: uboot
uboot:
	make -j8 -C u-boot thunderx_81xx_defconfig u-boot-nodtb.bin

.PHONY: atf
atf:
	make -j8 -C atf PLAT=t81 BL33=/dev/null SPD=none bl1
	make -j8 -C atf PLAT=t81 BL33=/dev/null SPD=none fip

.PHONY: uboot-fip
uboot-fip: uboot atf
	cp atf/build/t81/release/fip.bin fip.img
	./atf/tools/fiptool/fiptool update --nt-fw u-boot/u-boot-nodtb.bin fip.img

.PHONY: dts
dts:
	make -C dts
	./bdk/bin/fatfs-tool -i bdk/target-bin/bdk.bin cp dts/gw*.dtb /

.PHONY: clean
clean: clean-bdk clean-atf clean-uboot
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
