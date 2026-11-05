"""Package the supplied artwork into Android launcher density resources."""
import argparse
from pathlib import Path
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument("source", type=Path)
args = parser.parse_args()
source = Image.open(args.source).convert("RGBA")
if source.width != source.height:
    raise ValueError("Launcher artwork must be square")
master = ROOT / "mobile/assets/branding/app_icon.png"
master.parent.mkdir(parents=True, exist_ok=True)
source.save(master)
source.resize((512, 512), Image.Resampling.LANCZOS).save(
    master.with_name("app_mark.png")
)
for density, size in [("mdpi", 48), ("hdpi", 72), ("xhdpi", 96), ("xxhdpi", 144), ("xxxhdpi", 192)]:
    target = ROOT / f"mobile/android/app/src/main/res/mipmap-{density}/ic_launcher.png"
    target.parent.mkdir(parents=True, exist_ok=True)
    source.resize((size, size), Image.Resampling.LANCZOS).save(target)
    print(f"{density}: {size} x {size}")
