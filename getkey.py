#!/usr/bin/env python2

import binascii
import hashlib
import sys
import ecdsa

#
#
# Main entry point
#
def main():
    private_key = sys.argv[1]
    inf = open(private_key, "rb")
    pem = inf.read()
    inf.close()
    priv_key = ecdsa.SigningKey.from_pem(pem)
    pub = priv_key.get_verifying_key().to_string()
    assert len(pub) == 64, "Public key must be two 256 bits numbers, 64 bytes"
    r = pub[0:32] # R in big endian format
    s = pub[32:64] # S in big endian format
    ROTPK = r[::-1] + s[::-1]
    rotpk_sha = hashlib.sha256(ROTPK).digest()
    print( "0x" + binascii.hexlify(rotpk_sha[::-1]) )

# Call main
sys.exit(main())
