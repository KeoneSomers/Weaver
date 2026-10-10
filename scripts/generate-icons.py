"""Export approved Weaver artwork; requires Pillow (python -m pip install pillow)."""
from pathlib import Path
from io import BytesIO
import struct
from PIL import Image

root = Path(__file__).resolve().parents[1]
source = Image.open(root / "assets/weaver-source.png").convert("RGBA")
if source.width != source.height or source.width < 1024:
    raise ValueError("The approved source must be square and at least 1024 pixels wide")
if source.getchannel("A").getextrema() != (0, 255):
    raise ValueError("The approved source must preserve transparent corners")
icon = source.resize((1024, 1024), Image.Resampling.LANCZOS)
icon.save(root / "assets/weaver.png")
icon.save(root / "assets/weaver.ico", sizes=[(n, n) for n in (16, 20, 24, 28, 32, 36, 40, 48, 56, 64, 72, 80, 96, 128, 192, 256)])

# Include small 1x icons as well as Retina representations. Pillow's default
# ICNS writer omits the 16/32/64 px 1x chunks, so write the complete PNG family.
mac_sizes = {
    b"icp4": 16, b"icp5": 32, b"icp6": 64,
    b"ic07": 128, b"ic08": 256, b"ic09": 512, b"ic10": 1024,
    b"ic11": 32, b"ic12": 64, b"ic13": 256, b"ic14": 512,
}
entries = []
for kind, size in mac_sizes.items():
    stream = BytesIO()
    source.resize((size, size), Image.Resampling.LANCZOS).save(stream, format="PNG")
    payload = stream.getvalue()
    entries.append((kind, struct.pack(">I", 8 + len(payload)), payload))
toc = b"".join(kind + length for kind, length, _ in entries)
chunks = b"TOC " + struct.pack(">I", 8 + len(toc)) + toc
chunks += b"".join(kind + length + payload for kind, length, payload in entries)
(root / "assets/weaver.icns").write_bytes(b"icns" + struct.pack(">I", 8 + len(chunks)) + chunks)

# Freedesktop hicolor icons cover launcher/taskbar sizes and HiDPI displays.
for size in (16, 22, 24, 32, 48, 64, 96, 128, 192, 256, 512, 1024):
    directory = root / f"assets/icons/hicolor/{size}x{size}/apps"
    directory.mkdir(parents=True, exist_ok=True)
    source.resize((size, size), Image.Resampling.LANCZOS).save(directory / "weaver.png")

# KnotsUI accepts raw pixels. Embed a small version without a runtime PNG decoder.
(root / "assets/weaver.rgba").write_bytes(source.resize((64, 64), Image.Resampling.LANCZOS).tobytes())

# A standard .res embeds icons without requiring an external Windows RC tool.
ico = (root / "assets/weaver.ico").read_bytes()
count = struct.unpack_from("<H", ico, 4)[0]
def resource(kind, identifier, data, flags=0x1030, language=0x409):
    header = struct.pack("<IIHHHHIHHII", len(data), 32, 0xffff, kind, 0xffff, identifier, 0, flags, language, 0, 0)
    return header + data + b"\0" * (-len(data) % 4)
result = resource(0, 0, b"", flags=0, language=0)
group = struct.pack("<HHH", 0, 1, count)
for index in range(count):
    entry = ico[6 + index * 16:6 + (index + 1) * 16]
    length, offset = struct.unpack_from("<II", entry, 8)
    result += resource(3, index + 1, ico[offset:offset+length])
    group += entry[:12] + struct.pack("<H", index + 1)
result += resource(14, 1, group)
(root / "assets/weaver.res").write_bytes(result)
print("Exported Weaver PNG, ICO, ICNS, Windows resources, hicolor sizes and UI pixels")
