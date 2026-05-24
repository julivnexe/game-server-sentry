#!/usr/bin/env python3
"""
GameSpy3 NATNEG responder for Halo CE relay decoy.

Listens on UDP :27901, answers the multi-step NATNEG handshake so the
master server classifies our server as reachable. Without this, master
flags us strict-NAT and lobby clients can't get ping / can't join via
the server list.

Protocol reference: GameSpy SDK NATNEG header. Magic prefix
\xfd\xfc\x1e\x66\x6a\xb2 + 1-byte packet type + 1-byte version + 4-byte
cookie + body.

Packet types we handle:
  0x00 INIT       → reply INIT_ACK (0x01)
  0x02 ERTTEST    → reply ERTACK   (0x03)
  0x05 REPORT     → reply REPORTACK (0x06)
  0x07 NATIFY     → reply with NN_NATIFY echo
  0x08 PREINIT    → reply PREINIT_ACK (0x09)
  0x0c CONNECT    → reply CONNECT_ACK (0x0d)

Anything else we log and ignore. The responder is intentionally permissive
because we just need master to confirm we're alive — exact game-NEG state
is the haloceded↔client business, not ours.
"""
import socket
import struct
import sys
import time

LISTEN_PORT = 27901
MAGIC = b"\xfd\xfc\x1e\x66\x6a\xb2"


def reply_for(pkt: bytes) -> bytes | None:
    if not pkt.startswith(MAGIC) or len(pkt) < 12:
        return None
    ptype = pkt[6]
    version = pkt[7]
    cookie = pkt[8:12]
    body = pkt[12:]

    if ptype == 0x00:  # INIT
        # INIT_ACK preserves cookie, body is opaque echo
        return MAGIC + bytes([0x01, version]) + cookie + body
    if ptype == 0x02:  # ERTTEST (echo RTT)
        return MAGIC + bytes([0x03, version]) + cookie + body
    if ptype == 0x05:  # REPORT
        return MAGIC + bytes([0x06, version]) + cookie + body
    if ptype == 0x07:  # NATIFY
        return MAGIC + bytes([0x07, version]) + cookie + body
    if ptype == 0x08:  # PREINIT
        return MAGIC + bytes([0x09, version]) + cookie + body
    if ptype == 0x0C:  # CONNECT
        return MAGIC + bytes([0x0D, version]) + cookie + body
    return None


def main():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("0.0.0.0", LISTEN_PORT))
    print(f"natneg-responder: listening on 0.0.0.0:{LISTEN_PORT}", flush=True)
    while True:
        try:
            data, addr = s.recvfrom(2048)
        except KeyboardInterrupt:
            return
        reply = reply_for(data)
        if reply is None:
            print(
                f"[{time.strftime('%H:%M:%S')}] {addr} unknown/short ({len(data)}B): {data[:16].hex()}",
                flush=True,
            )
            continue
        s.sendto(reply, addr)
        print(
            f"[{time.strftime('%H:%M:%S')}] {addr} type=0x{data[6]:02x} → reply 0x{reply[6]:02x} ({len(reply)}B)",
            flush=True,
        )


if __name__ == "__main__":
    sys.exit(main())
