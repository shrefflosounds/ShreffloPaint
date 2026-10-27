#!/usr/bin/env python3
import os
import sys
import subprocess
import shutil

home = os.path.expanduser("~")

source_dirs = [
    os.path.join(home, "Desktop", "PNGs for art", "Shrefflo", "characters"),
    os.path.join(home, "Desktop", "PNGs for art", "Shrefflo"),
    os.path.join(home, "Desktop", "Shrefflo stuff", "Transparent PNGs")
]

target_dirs = [
    "/Applications/ShreffloPaint.app/Contents/Resources/share/tuxpaint/stamps/00_shrefflo",
    os.path.join(home, "Desktop", "ShreffloPaint.app", "Contents", "Resources", "share", "tuxpaint", "stamps", "00_shrefflo")
]

desktop_stamps_dir = os.path.join(home, "Desktop", "Shrefflo Stamps")
os.makedirs(desktop_stamps_dir, exist_ok=True)

for td in target_dirs:
    os.makedirs(td, exist_ok=True)

# 1. Install Top 3 Priority Stamps
top_three = [
    ("01-reem8", os.path.join(home, "Desktop", "REem8.png"), "REem8"),
    ("02-sf", os.path.join(home, "Desktop", "SF.png"), "SF"),
    ("03-heknah", os.path.join(home, "Desktop", "Heknah.png"), "Heknah")
]

for clean_name, src_p, title in top_three:
    if os.path.exists(src_p):
        for td in target_dirs:
            shutil.copy2(src_p, os.path.join(td, f"{clean_name}.png"))
            with open(os.path.join(td, f"{clean_name}.dat"), "w") as df:
                df.write("scale 1.0\n")
            with open(os.path.join(td, f"{clean_name}.txt"), "w") as tf:
                tf.write(f"{title}\n")
        shutil.copy2(src_p, os.path.join(desktop_stamps_dir, f"{clean_name}.png"))

processed_names = {"01-reem8", "02-sf", "03-heknah", "reem8", "sf", "heknah"}
count = 3

# 2. Gather other PNGs
for sdir in source_dirs:
    if not os.path.exists(sdir):
        continue
    for root, _, files in os.walk(sdir):
        for f in sorted(files):
            if not f.lower().endswith(".png"):
                continue
            if f.startswith("."):
                continue
            
            src_path = os.path.join(root, f)
            base = os.path.splitext(f)[0]
            clean_name = base.lower().replace(" ", "-").replace("_", "-")
            
            # Avoid leading '0-' so it doesn't sort before '01-'
            if clean_name.startswith("0-"):
                clean_name = clean_name[2:]
                
            if clean_name in processed_names:
                continue
            processed_names.add(clean_name)
            
            tmp_out = f"/tmp/stamp_{clean_name}.png"
            res = subprocess.run(["sips", "-Z", "300", src_path, "--out", tmp_out],
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            if res.returncode != 0:
                continue
            
            title = clean_name.replace("-", " ").title()
            
            for td in target_dirs:
                dest_png = os.path.join(td, f"{clean_name}.png")
                dest_dat = os.path.join(td, f"{clean_name}.dat")
                dest_txt = os.path.join(td, f"{clean_name}.txt")
                
                shutil.copy2(tmp_out, dest_png)
                with open(dest_dat, "w") as df:
                    df.write("scale 1.0\n")
                with open(dest_txt, "w") as tf:
                    tf.write(f"{title}\n")
            
            shutil.copy2(tmp_out, os.path.join(desktop_stamps_dir, f"{clean_name}.png"))
            
            if os.path.exists(tmp_out):
                os.remove(tmp_out)
            
            count += 1

print(f"Successfully configured {count} Shrefflo stamps in 00_shrefflo and on Desktop!")
