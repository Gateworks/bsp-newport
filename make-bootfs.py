#! /usr/bin/env python2

import os
import sys
import binascii
import struct
import time
import argparse
import uuid

# BDK image heade for Thunder is
#   Offset  Size    Description
#   0x00    4       Raw instruction for skipping header
#   0x04    4       Length of the image, includes header
#   0x08    8       Magic string "THUNDERX"
#   0x10    4       CRC32 of image + header. These bytes are zero when calculating the CRC
#   0x14    4       Zero, reserved for future use
#   0x18    64      ASCII Image name. Must always end in zero
#   0x58    32      ASCII Version. Must always end in zero
#   0x78    136     Zero, reserved for future use
#   0x100   -       Beginning of image. Header is always 256 bytes.
# UPDATE THIS FILE WHEN EVEN BDK HEADER FORMAT CHANGES.



#ATF image header for ThunderX is
#  offset       size    Description
#   0x00         4       lenght of the image
#   0x04         8       Reserved
#   0x0c         4       CRC32 image   
#   0x10         64      Image name
#   0x50         80    Reserved


BDK_HEADER_MAGIC = "THUNDERX"
BDK_HEADER_SIZE = 0x100

ATF_HEADER_SIZE = 0x100
ATF_BL1_OFFSET = 0xE00000 # must match bdk init/app.bin:ATF_OFFSET
ATF_BL2_OFFSET = 0xF00000 # must match atf thunder_io_storage.c:fip_block_spec
ATF_TBL_OFFSET = 0x480000 # unused


def load_file(filename):
    inf = open(filename, "rb")
    file = inf.read()
    inf.close()
    return file
  
def print_common_atf(data, offset):
    atflen = struct.unpack_from('<I',data, (offset + 0x0))
    if(atflen[0]):
        print ' Image Len:'+str(atflen[0])
        print ' Image Name: ' +data[(offset+0x10) : (offset +0x10 +64)]

def print_common_bdk(data, offset):
    bdklen = struct.unpack_from('<I',data, (offset + 0x4))
    if(bdklen[0]):
        print ' Image Len:'+str(bdklen[0])
        print ' Magic String: ' + data[offset+0x8:offset+0x10]
        print ' Image Name: ' +data[(offset+0x18) : (offset +0x18 +64)]
        print ' Version: ' + data[(offset + 0x58) : (offset + 0x58 + 32)]

def print_common_fip_header(data, offset):
    toc = struct.unpack_from('<IIQ', data, (offset))
    print ' Name: ' + hex(toc[0])
    print ' Serial: ' + hex(toc[1])
    if (toc[2] != 0):
        print ' Flags: ' + hex(toc[2])

def print_common_fip_entry(data, offset, entry):
    entry = struct.unpack_from('<16sQQQ', data, (offset + 0x10 + 0x28 * entry))
    u = uuid.UUID(bytes_le = entry[0])
    if (str(u) == '00000000-0000-0000-0000-000000000000'):
        return False
    print ' ----------------------------------------------'
    print '  UUID: ' + str(u)
    print '  Offset (inside FIP): ' + hex(entry[1])
    print '  Offset (inside image): ' + hex(entry[1] + offset)
    print '  Length: ' + str(entry[2]) + ' / ' + hex(entry[2])
    if (entry[3] != 0):
        print '  Flags: ' + hex(entry[3])
    return True

def print_fip_data(data, offset):
    print_common_fip_header(data, offset)
    entry = 0
    while print_common_fip_entry(data, offset, entry):
        entry += 1

def print_bdk_headers(bootfs_data):
    print '***********************************************'
    print ' BDK BOOT STUB(Non trusted)'
    print_common_bdk(bootfs_data,0x20000)
    print '***********************************************'
        
    print '***********************************************'
    print ' BDK BOOT STUB(Trusted)'
    print_common_bdk(bootfs_data,0x50000)
    print '***********************************************'

    print '***********************************************'
    print ' BDK Diagnostics'
    print_common_bdk(bootfs_data,0x80000)
    print '***********************************************'

    print '***********************************************'
    print ' BDK: ATF BL1'
    print_common_bdk(bootfs_data,0x400000)
    print '***********************************************'


def print_atf_headers(bootfs_data):
    print '***********************************************'
    print ' ATF FIP'
    print_common_atf(bootfs_data,0x480000+(1*0x100))
    print '***********************************************'

def print_fip_headers(bootfs_data):
    print '***********************************************'
    print ' FIP contents'
    print_fip_data(bootfs_data,ATF_BL2_OFFSET)
    print '***********************************************'

def print_bootfs(filename):
    bootfs_data = load_file(filename)
    print_bdk_headers(bootfs_data)
    print_atf_headers(bootfs_data)
    print_fip_headers(bootfs_data)


def pack(width, data):
    if width == 1:
        return struct.pack("<B", data)
    elif width == 2:
        return struct.pack("<H", data)
    elif width == 4:
        return struct.pack("<I", data)
    elif width == 8:
        return struct.pack("<Q", data)
    else:
        raise Exception("Invalid width")



def write_file(filename, data, offset):
    fhandle = open(filename, 'r+b')
    fhandle.seek(offset, 0)
    fhandle.write(data)
    fhandle.close()


def update_atf_header(filename,imagename, data, offset,tbl_idx):
    tbl_offset = ATF_TBL_OFFSET + (tbl_idx * 0x100)
    #build a atf header
    header = pack(4,len(data))
    header += pack(8,0)
    crc32 = 0xffffffffL & binascii.crc32(data)
    header += pack(4, crc32)
    name = imagename[0:63]
    header += name
    header += "\0" * (64 - len(name))
    header += "\0" * (ATF_HEADER_SIZE - len(header))
    fhandle = open(filename, 'r+b')
    fhandle.seek(tbl_offset, 0)
    fhandle.write(header)
    fhandle.close()
    write_file(filename, data, offset)


def update_bdk_header(filename, image_name, image_version, data, offset):
    # Save the 4 bytes at the front for the new header
    raw_instruction = data[0:4]
    # Remove the existing header
    data = data[BDK_HEADER_SIZE:]
    # Header begins with one raw instruction for 4 bytes
    header = raw_instruction
    # Total length
    header += pack(4, BDK_HEADER_SIZE + len(data))
    # Eight bytes of magic number
    header += BDK_HEADER_MAGIC
    # CRC - filled later
    header += pack(4, 0)
    # Reserved 4 bytes
    header += pack(4, 0)
    # 32 bytes of Name
    name = image_name[0:63] # Truncate to 63 bytes, room for \0
    header += name
    header += "\0" * (64 - len(name))
    # 16 bytes of Version
    v = image_version[0:31] # Truncate to 31 bytes, room for \0
    header += v
    header += "\0" * (32 - len(v))
    # Pad to header length
    header += "\0" * (BDK_HEADER_SIZE - len(header))
    # Make sure we're the right length
    assert(len(header) == BDK_HEADER_SIZE)

    # Combine the header and the data
    data = header + data
    # Fix the CRC
    crc32 = 0xffffffffL & binascii.crc32(data)
    data = data[0:16] + pack(4,crc32) + data[20:]
    write_file(filename, data, offset)


parser = argparse.ArgumentParser(description='argumnets for THUNDERX BOOTFS creationg.')
parser.add_argument( '--bs', '--bdk-image', help='bdk boot strap image') 
parser.add_argument('--bl1', '--atf-bl1', help='atf boot stage 1')
parser.add_argument('-s', '--secure', help='set to 1 to build atf boot stage 1 for secure boot')
parser.add_argument('--fip', '--atf-fip', help='atf boot stage 2 and 3.1/3.2/3.3')
parser.add_argument('-f', '--bootfs', required=True, help='file to be used for bootfs')
parser.add_argument('-p','--printfs', help='print headers included in a given ThundeX bootfs', action='store_true')
args = parser.parse_args()


if(args.printfs):
    print_bootfs(args.bootfs)
    exit()

if not os.path.isfile(args.bootfs):
    open(args.bootfs, "w").close()

if(args.bs):
    bs_data = load_file(args.bs)
    write_file(args.bootfs, bs_data, 0)

if(args.bl1):
    bl1_data = load_file(args.bl1)
    if(args.secure):
        update_bdk_header(args.bl1, 'ATF stage 1', '2.0',  bl1_data, 0)
    else:
        update_bdk_header(args.bootfs, 'ATF stage 1', '1.0',  bl1_data, ATF_BL1_OFFSET)

if(args.fip):
    bl2_data = load_file(args.fip)
    #update_atf_header(args.bootfs, 'ATF stage 2',  bl2_data, ATF_BL2_OFFSET,1)
    write_file(args.bootfs, bl2_data, ATF_BL2_OFFSET)
