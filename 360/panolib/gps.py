"""
GPS coordinate extraction from EXIF, used for the krpano <scene lat="" lng="">
attributes. Ported from krpano.py's get_gps_coordinates().
"""

import json
import os
import shutil
import subprocess
import sys

from PIL import Image


def get_gps_coordinates(image_path: str) -> tuple[str, str, str]:
    """
    Extract GPS lat, lng, alt from EXIF. Returns formatted strings or "" if absent.
    Primary: Pillow GPS IFD. Fallback: exiftool subprocess.
    """
    lat_str, lng_str, alt_str = "", "", ""

    # Primary: Pillow EXIF GPS IFD (tag 34853 = 0x8825)
    try:
        with Image.open(image_path) as _img:
            gps_ifd = _img.getexif().get_ifd(34853)

        if gps_ifd:
            def _dms_to_decimal(dms_tuple) -> float:
                d, m, s = (float(v) for v in dms_tuple)
                return d + m / 60.0 + s / 3600.0

            lat_dms = gps_ifd.get(2)   # GPSLatitude
            lat_ref = gps_ifd.get(1)   # GPSLatitudeRef  ('N'/'S')
            lng_dms = gps_ifd.get(4)   # GPSLongitude
            lng_ref = gps_ifd.get(3)   # GPSLongitudeRef ('E'/'W')
            alt_val = gps_ifd.get(6)   # GPSAltitude
            alt_ref = gps_ifd.get(5)   # GPSAltitudeRef  (0=above, 1=below)

            if lat_dms and lat_ref and lng_dms and lng_ref:
                lat = _dms_to_decimal(lat_dms)
                lng = _dms_to_decimal(lng_dms)
                if str(lat_ref).upper().strip() == 'S':
                    lat = -lat
                if str(lng_ref).upper().strip() == 'W':
                    lng = -lng
                lat_str = f"{lat:.8f}"
                lng_str = f"{lng:.8f}"

            if alt_val is not None:
                alt = float(alt_val)
                if alt_ref and int(alt_ref) == 1:
                    alt = -alt
                alt_str = f"{alt:.2f}"

    except Exception:
        pass  # malformed EXIF or unsupported format - fall through

    if lat_str and lng_str:
        return lat_str, lng_str, alt_str

    # Fallback: exiftool
    exiftool_bin = shutil.which("exiftool")
    if exiftool_bin:
        try:
            result = subprocess.run(
                [exiftool_bin, "-j", "-n", image_path],
                capture_output=True, text=True, timeout=15,
            )
            if result.returncode == 0 and result.stdout.strip():
                data = json.loads(result.stdout)
                if data:
                    rec = data[0]
                    et_lat = rec.get("GPSLatitude")
                    et_lng = rec.get("GPSLongitude")
                    et_alt = rec.get("GPSAltitude")
                    if et_lat is not None and et_lng is not None:
                        lat_str = f"{float(et_lat):.8f}"
                        lng_str = f"{float(et_lng):.8f}"
                    if et_alt is not None:
                        alt_str = f"{float(et_alt):.2f}"
        except Exception:
            pass  # exiftool failed or timed out

    if not lat_str or not lng_str:
        print(f"Warning: No GPS data found for {os.path.basename(image_path)}",
              file=sys.stderr)

    return lat_str, lng_str, alt_str
