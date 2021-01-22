#!/usr/bin/python3

# GPTGen: GPT table generator

import argparse
import base64
import binascii
import hashlib
import os
import struct
import sys
import uuid
import binascii
import math

supported_partitions_types = [ 'fat16', 'linux', 'reserved' ]
def parts_usage():
    print('Wrong partition argument. Must be "<name>:<type>:<start>:<size>"')

class PartitionDesc:
    pass

def do_arg_parse():
    parser = argparse.ArgumentParser(
        usage='gptgen.py\n',
        description='TODO\n', formatter_class=argparse.RawTextHelpFormatter)
    parser.add_argument('--disk-size', action='store', dest='disk_size',
                      required=True, nargs=1,
            help='This is required for the protective MBR header and GPT header')
    parser.add_argument('--part', '-p', action='append', dest='parts',
            required='True',
            help='Patitions configuration. This argument can be used\n'
            'multiple time to define multiple partitions. The format of each\n'
            'partition must be: "<name>:<type>:<start>:<size>". Example:\n'
            './gptgen.py ... -p "foo:fat16:1M:16M" -p "bar:linux:16M:32M" ...')
    parser.add_argument('--out', action='store', dest='out_path',
                        nargs=1, required=True,
            help='This is the path of the resulting binary.\n')

    args = parser.parse_args()

    return args

def zero_padding(num_bytes):
    fill = struct.pack("<B", 0x00)
    return fill * num_bytes

def to_sectors(val):
    suf = str(val)[-1]

    try:
        if suf == 'k' or suf == 'K':
            value = int(val[:-1]) * 1024
        elif suf == 'm' or suf == 'M':
            value = int(val[:-1]) * 1024 * 1024
        elif suf == 'g' or suf == 'G':
            value = int(val[:-1]) * 1024 * 1024 * 1024
        else:
            value = int(val)

    except ValueError:
        return None

    # Return the number of sectors
    return int(value / 512)

def get_qval_offset(byte_array, offset):
    return struct.unpack_from('<Q', byte_array, offset)

def get_cur_lba(byte_array):
    return get_qval_offset(byte_array, 0x18)

def get_descs_part_lba(byte_array):
    return get_qval_offset(byte_array, 0x48)


def create_protective_mbr_header(disk_size):
    mbr = zero_padding(0x1be)
    mbr += struct.pack('<B', 0x00)
    # CHS address of 1st partition sector = chs(1) = 0x200
    mbr += struct.pack('<BBB', 0x00, 0x02, 0x00)
    # Partition type, must be 0xEE
    mbr += struct.pack('<B', 0xEE)
    # CHS address of last partition sector. It can be and arbitrary value
    mbr += struct.pack('<BBB', 0xFF, 0xFF, 0xFF)
    # LBA address of first partition sector
    mbr += struct.pack('<L', 0x1)
    mbr += struct.pack('<L', to_sectors(str(disk_size)) - 1)

    mbr += zero_padding(512 - len(mbr) - 2)

    mbr += struct.pack('<BB', 0x55, 0xaa)

    assert(len(mbr) == 512)

    return mbr

# disk_size must be the size of the physical disk, not of the logical partitions
def create_gpt_header(disk_size, partition_descs):
    disk_sectors = to_sectors(str(disk_size))
    if disk_sectors is None:
        print('GPTgen: Wrong disk size')
        return None
    last_sector = disk_sectors - 1

    uuid_hex = uuid.uuid4().hex

    # Starting LBA of array of partition entries
    part_entries_lba = 2
    cur_lba = 0x1
    bkp_lba = last_sector

    # 0x00: GPT signature
    gpt_header = struct.pack('<Q', 0x5452415020494645)
    # 0x08: GPT Revision
    gpt_header += struct.pack('<L', 0x00010000)
    # 0x0C: Header size, 92 bytes
    gpt_header += struct.pack('<L', 0x0000005c)
    # 0x10: CRC32: It will be filled later
    gpt_header += struct.pack('<L', 0x00000000)
    # 0x14: Reserved
    gpt_header += struct.pack('<L', 0x00000000)
    # 0x18: Current LBA
    gpt_header += struct.pack('<Q', cur_lba)
    # 0x20: Backup LBA
    gpt_header += struct.pack('<Q', bkp_lba)
    # 0x28: First usable LBA (usually, 34)
    gpt_header += struct.pack('<Q', 34)
    # 0x30: Last usable LBA (usually, last sector - 34)
    gpt_header += struct.pack('<Q', disk_sectors - 34)
    # 0x38: Disk GUID
    gpt_header += struct.pack('<QQ', int(uuid_hex[16:32], 16), int(uuid_hex[0:16], 16))
    # 0x48: Starting LBA of array of partition entries
    gpt_header += struct.pack('<Q', part_entries_lba)
    # 0x50: Number of partition entries
    gpt_header += struct.pack('<L', 0x80)
    # 0x54: Size of single partition entry
    gpt_header += struct.pack('<L', 128)
    # 0x58: CRC32 of partition entries array in LE
    gpt_header += struct.pack('<L', 0x00000000)
    # 0x5C: Reserved, must be zero till the end of the block
    gpt_header += zero_padding(512 - 92)

    assert(len(gpt_header) == 512)

    # conver to bytearray
    gpt_header_ba = bytearray(gpt_header)

    # Compute CRC32 of partition descriptors
    crc32 = binascii.crc32(partition_descs)
    struct.pack_into('<L', gpt_header_ba, 0x58, crc32)

    gpt_header = bytes(gpt_header_ba)

    # Compute CRC32 of the whole header without padding
    crc32 = binascii.crc32(gpt_header[0:0x5C])

    gpt_header_ba = bytearray(gpt_header)
    struct.pack_into('<L', gpt_header_ba, 0x10, crc32)

    return bytes(gpt_header_ba)

def _create_gpt_partition_desc(start, size, ptype, name):
    uuid_hex = uuid.uuid4().hex
    attributes = 0

    start_lba = to_sectors(start)
    if start_lba is None:
        print('GPTgen: Wrong partition start')
        return None
    last_lba = to_sectors(size) - 1
    if last_lba is None:
        print('GPTgen: Wrong partition size')
        return None

    name_hex = name.encode('utf-16LE')
    # Two chars per byte
    if len(name) > 72 * 2:
        name_hex = name_hex[:72 * 2]
    name_sz = int(len(name_hex))

    part_desc = b''
    # 0x00: Partition type GUID
    # According to the documentation, the first three dash-delimited fields of
    # the GUID are stored little endian, and the last two fields are not.
    if ptype == 'fat16':
        # EBD0A0A2-B9E5-4433-87C0-68B6B72699C7: Basic data partition
        part_desc += struct.pack('<L', 0xEBD0A0A2)
        part_desc += struct.pack('<H', 0xB9E5)
        part_desc += struct.pack('<H', 0x4433)
        part_desc += struct.pack('>H', 0x87C0)
        part_desc += struct.pack('>L', 0x68B6B726)
        part_desc += struct.pack('>H', 0x99C7)
        # bootable
        attributes |= 0x4
    elif ptype == 'linux':
        # 0FC63DAF-8483-4772-8E79-3D69D8477DE4: Linux filesystem data
        part_desc += struct.pack('<L', 0x0FC63DAF)
        part_desc += struct.pack('<H', 0x8483)
        part_desc += struct.pack('<H', 0x4772)
        part_desc += struct.pack('>H', 0x8e79)
        part_desc += struct.pack('>L', 0x3D69D847)
        part_desc += struct.pack('>H', 0x7DE4)
        # bootable
        attributes |= 0x4
    elif ptype == 'reserved':
        # 8DA63339-0007-60C0-C436-083AC8230908: Reserved
        part_desc += struct.pack('<L', 0x8DA63339)
        part_desc += struct.pack('<H', 0x0007)
        part_desc += struct.pack('<H', 0x60C0)
        part_desc += struct.pack('>H', 0xC436)
        part_desc += struct.pack('>L', 0x083AC823)
        part_desc += struct.pack('>H', 0x0908)
        # protective partitions are required to function
        attributes |= 1
    else:
        print('Unsupported partition type')
        return None

    # 0x10: Partition GUID
    part_desc += struct.pack('<QQ', int(uuid_hex[16:32], 16), int(uuid_hex[0:16], 16))
    # 0x20: First LBA
    part_desc += struct.pack('<Q', start_lba)
    # 0x28: Last LBA
    part_desc += struct.pack('<Q', last_lba)
    # 0x30: Attributes flags: 0x4 is bootable flag
    part_desc += struct.pack('<Q', attributes)
    # 0x38: Partition name (72 bytes)
    part_desc += name_hex
    part_desc += zero_padding(72 - name_sz)

    assert(len(part_desc) == 128)

    return part_desc

def create_gpt_partitions_descs(descs):
    descs_bin = b''
    for p in descs:
        print('Creating descriptor for partition %s' % p.name)
        descs_bin += _create_gpt_partition_desc(p.start, p.size, p.type, p.name)

    return descs_bin

args = do_arg_parse()
if args == None:
    print('Error while parsing user arguments')
    sys.exit(1)

if len(args.parts) == 0:
    print('No partition defined')
    sys.exit(1)

# Check disk size
if to_sectors(str(args.disk_size[0])) is None:
    print('Wrong disk size value')
    sys.exit(1)
args.disk_size = str(args.disk_size[0])

partitions = []
for _p in args.parts:

    p_vals = _p.split(':')
    if len(p_vals) != 4:
        parts_usage()
        sys.exit(1)

    p = PartitionDesc()
    p.name = p_vals[0]

    if p_vals[1] not in supported_partitions_types:
        parts_usage()
        sys.exit(1)
    p.type = p_vals[1]

    if to_sectors(p_vals[2]) is None or to_sectors(p_vals[3]) is None:
        parts_usage()
        sys.exit(1)

    p.start = p_vals[2]
    p.size = p_vals[3]

    partitions.append(p)

mbr = create_protective_mbr_header(args.disk_size)
if mbr is None:
    print('Error while crearting MBR')
    sys.exit(1)

part_descs = create_gpt_partitions_descs(partitions)
assert(len(part_descs) == len(partitions) * 128)
if part_descs is None:
    print('Error while crearting partitions descriptors')
    sys.exit(1)
# Pad it to the next sector
part_descs_padded = part_descs + zero_padding((4 - len(partitions) % 4) * 128)
# Pad it to 32 sectors
part_descs_padded += zero_padding(32 * 512 - len(part_descs_padded))

gpt_h = create_gpt_header(args.disk_size, part_descs_padded)
if gpt_h is None:
    print('Error while creating GPT header')
    sys.exit(1)

print('MBR header LBA: 0x%x' % 0)
print('Primary GPT header LBA: 0x%x' % get_cur_lba(gpt_h))
print('Partitions descriptors LBA: 0x%x' % 2)
print('Partitions descriptors LBA needed: %d' % math.ceil(len(args.parts)/4))

# generate image
disk_start = b''
disk_start += mbr
disk_start += gpt_h
disk_start += part_descs_padded

# write image
print('Writing output image to %s' % args.out_path[0])
out = open(args.out_path[0], "wb")
out.write(disk_start)
out.close()

