"""Export Weaver's code-defined vector mark as native application icons."""
from pathlib import Path
import struct
from PIL import Image, ImageDraw

root = Path(__file__).resolve().parents[1]
scale = 8
canvas = Image.new("RGBA", (256 * scale, 256 * scale))
draw = ImageDraw.Draw(canvas)
draw.rounded_rectangle(tuple(v * scale for v in (8, 8, 248, 248)), radius=56 * scale, fill="#222326")
points = [(55, 74), (89, 182), (128, 105), (167, 182), (201, 74)]
draw.line([(x * scale, y * scale) for x, y in points], fill="#B4A0FF", width=19 * scale, joint="curve")
for x, y in points:
    r = 9.5
    draw.ellipse(((x-r)*scale, (y-r)*scale, (x+r)*scale, (y+r)*scale), fill="#B4A0FF")
icon = canvas.resize((1024, 1024), Image.Resampling.LANCZOS)
icon.save(root / "assets/weaver.png")
icon.save(root / "assets/weaver.icns")
icon.save(root / "assets/weaver.ico", sizes=[(n, n) for n in (16, 24, 32, 48, 64, 128, 256)])

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
