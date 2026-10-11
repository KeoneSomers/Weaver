"""Convert the bundled SVG's rects/polygons to native KnotsUI vector commands."""
from pathlib import Path
import hashlib
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parents[1]
source = (root / "assets/weaver-badge.svg").read_bytes().replace(b"\r", b"")
svg = ET.fromstring(source)
if svg.attrib["viewBox"] != "0 0 30 30":
    raise ValueError("The badge must use the 30 px UI coordinate system")
shapes = [e for e in svg if e.tag.rsplit("}", 1)[-1] != "title"]
if [e.attrib.get("id") for e in shapes[:2]] != ["border", "tile"]:
    raise ValueError("The border and tile rectangles must be the first two shapes")
lines = ["// Generated from assets/weaver-badge.svg by scripts/generate-badge.py.",
         'const ui = @import("ui");',
         "pub const source_sha256 = [32]u8{" + ",".join(str(v) for v in hashlib.sha256(source).digest()) + "};",
         "pub const commands = [_]ui.component.Canvas.DrawCmd{"]
for element in svg:
    tag = element.tag.rsplit("}", 1)[-1]
    if tag == "title":
        continue
    a = element.attrib
    color = a["fill"].lstrip("#")
    if len(color) != 6:
        raise ValueError("Only solid RGB fills are supported")
    # SVG fills are sRGB; KnotsUI stores linear colors for its native renderer.
    int(color, 16)
    rgba = '(ui.Color.hex("#' + color + '") catch unreachable).value'
    if tag == "rect":
        values = ",".join(f".{field}={float(a[attr])}" for field, attr in (("x","x"),("y","y"),("w","width"),("h","height")))
        lines.append(".{.fill_rect=.{" + values + f",.corner_radius=.all({float(a.get('rx', 0))}),.color={rgba}" + "}},")
    elif tag == "polygon":
        points = ",".join(".{" + ",".join(str(float(v)) for v in point.split(",")) + "}" for point in a["points"].split())
        lines.append(".{.fill_convex_polygon=.{.points=&.{" + points + "},.color=" + rgba + "}},")
    else:
        raise ValueError(f"Unsupported SVG element: {tag}")
lines.append("};")
(root / "src/brand_badge_svg.zig").write_text("\n".join(lines) + "\n", encoding="utf-8")
print("Exported Weaver SVG to native vector commands")
