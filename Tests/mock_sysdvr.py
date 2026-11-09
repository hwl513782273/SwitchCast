#!/usr/bin/env python3
"""模拟 SysDVR 主机：握手 + TCP Bridge 数据流 + UDP 发现广播（仅用于本机验证）"""
import socket
import struct
import sys
import threading
import time

VIDEO_PORT = 9911
AUDIO_PORT = 9922
DISCOVERY_PORT = 19999
PROTOCOL = "02"
MAGIC = 0xCCCCCCCC


def split_access_units(data: bytes):
    positions = []
    index = 0
    while True:
        found = data.find(b"\x00\x00\x01", index)
        if found < 0:
            break
        positions.append(found)
        index = found + 3

    units = []
    current = None
    for order, position in enumerate(positions):
        nal_start = position + 3
        if nal_start >= len(data):
            continue
        nal_type = data[nal_start] & 0x1F
        end = positions[order + 1] if order + 1 < len(positions) else len(data)
        chunk = data[position:end]
        if nal_type == 9:
            if current:
                units.append(bytes(current))
            current = bytearray(chunk)
        else:
            if current is None:
                current = bytearray()
            current += chunk
    if current:
        units.append(bytes(current))
    return units


def packet(payload: bytes, is_video: bool, timestamp_us: int) -> bytes:
    flags = 0x01 if is_video else 0x02
    flags |= 0x04
    header = struct.pack("<IIQBB", MAGIC, len(payload), timestamp_us, flags, 0xFF)
    return header + payload


def handshake(conn: socket.socket, stream_name: str):
    conn.sendall(b"SysDVR|" + PROTOCOL.encode() + b"\x00")
    request = b""
    while len(request) < 16:
        chunk = conn.recv(16 - len(request))
        if not chunk:
            return False
        request += chunk
    magic, version, meta, vflags, batching, fflags = struct.unpack("<IHBBBB", request[:10])
    print(f"[{stream_name}] 握手 magic=0x{magic:08X} ver=0x{version:04X} meta={meta:02b} videoFlags={vflags:02b}", flush=True)
    conn.sendall(struct.pack("<I", 6))
    return True


def serve_video(units):
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(("127.0.0.1", VIDEO_PORT))
    server.listen(4)
    print(f"视频端口 {VIDEO_PORT} 就绪，{len(units)} 个访问单元", flush=True)

    while True:
        conn, _ = server.accept()
        if not handshake(conn, "video"):
            conn.close()
            continue
        start = time.monotonic()
        frame = 0
        try:
            while True:
                target = start + frame / 30.0
                delay = target - time.monotonic()
                if delay > 0:
                    time.sleep(delay)
                payload = units[frame % len(units)]
                conn.sendall(packet(payload, True, int((time.monotonic() - start) * 1e6)))
                frame += 1
        except (BrokenPipeError, ConnectionResetError):
            print("[video] 客户端断开", flush=True)
        finally:
            conn.close()


def serve_audio(pcm: bytes):
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(("127.0.0.1", AUDIO_PORT))
    server.listen(4)
    print(f"音频端口 {AUDIO_PORT} 就绪，{len(pcm)} 字节 PCM", flush=True)

    chunk_size = 0x1000
    while True:
        conn, _ = server.accept()
        if not handshake(conn, "audio"):
            conn.close()
            continue
        start = time.monotonic()
        offset = 0
        chunk_index = 0
        try:
            while True:
                target = start + chunk_index * (chunk_size / 4) / 48000.0
                delay = target - time.monotonic()
                if delay > 0:
                    time.sleep(delay)
                chunk = pcm[offset:offset + chunk_size]
                if len(chunk) < chunk_size:
                    offset = 0
                    chunk = pcm[offset:offset + chunk_size]
                    offset = chunk_size
                else:
                    offset += chunk_size
                conn.sendall(packet(chunk, False, int((time.monotonic() - start) * 1e6)))
                chunk_index += 1
        except (BrokenPipeError, ConnectionResetError):
            print("[audio] 客户端断开", flush=True)
        finally:
            conn.close()


def advertise(serial: str):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    payload = f"SysDVR|6.3|{PROTOCOL}|{serial}".encode()
    while True:
        try:
            sock.sendto(payload, ("255.255.255.255", DISCOVERY_PORT))
        except OSError:
            pass
        time.sleep(2)


def main():
    h264_path, pcm_path = sys.argv[1], sys.argv[2]
    serial = sys.argv[3] if len(sys.argv) > 3 else "XAJ1000000000"

    units = split_access_units(open(h264_path, "rb").read())
    pcm = open(pcm_path, "rb").read()
    print(f"载入 {len(units)} 帧 / {len(pcm)} 字节音频", flush=True)

    threading.Thread(target=advertise, args=(serial,), daemon=True).start()
    threading.Thread(target=serve_audio, args=(pcm,), daemon=True).start()
    serve_video(units)


if __name__ == "__main__":
    main()
