# Generate a minimal RGBA PNG from a P7 PAM file (no third-party deps).
# Used to populate Assets.xcassets image sets from mkicon.py output.

import struct
import sys
import zlib

def read_pam(path):
    with open(path, "rb") as f:
        assert f.readline() == b"P7\n"
        width = height = None
        for line in iter(f.readline, b""):
            words = line.decode("ASCII").strip().split()
            if not words:
                continue
            if words[0] == "WIDTH":
                width = int(words[1])
            elif words[0] == "HEIGHT":
                height = int(words[1])
            elif words[0] == "DEPTH":
                assert int(words[1]) == 4
            elif words[0] == "TUPLTYPE":
                assert words[1] == "RGB_ALPHA"
            elif words[0] == "ENDHDR":
                break
        data = f.read()
        assert len(data) == width * height * 4
        return width, height, data

def write_png(path, width, height, rgba):
    def chunk(tag, payload):
        return (struct.pack(">I", len(payload)) + tag + payload +
                struct.pack(">I", zlib.crc32(tag + payload) & 0xFFFFFFFF))

    ihdr = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    rows = []
    for y in range(height):
        rows.append(b"\x00" + rgba[y * width * 4:(y + 1) * width * 4])
    idat = zlib.compress(b"".join(rows), 9)

    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n")
        f.write(chunk(b"IHDR", ihdr))
        f.write(chunk(b"IDAT", idat))
        f.write(chunk(b"IEND", b""))

if __name__ == "__main__":
    inpath, outpath = sys.argv[1:3]
    width, height, rgba = read_pam(inpath)
    write_png(outpath, width, height, rgba)
