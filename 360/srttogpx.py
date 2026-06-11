#!/usr/bin/env python3
"""Convert DJI SRT telemetry files to GPX format."""

import argparse
import re
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path
from xml.etree import ElementTree as ET
from xml.dom import minidom


def parse_srt(path: Path, tz_offset: int) -> list[dict]:
    text = path.read_text(encoding="utf-8", errors="replace")
    blocks = re.split(r"\n\s*\n", text.strip())

    dt_pattern = re.compile(r"(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}(?:\.\d+)?)")
    field_pattern = re.compile(r"\[(\w+):\s*([^\]]+)\]")
    # abs_alt and rel_alt share one bracket, e.g. [rel_alt: 28.700 abs_alt: 564.312]
    abs_alt_pattern = re.compile(r"abs_alt:\s*([\d.]+)")
    rel_alt_pattern = re.compile(r"rel_alt:\s*([\d.]+)")

    points = []
    for block in blocks:
        # Strip HTML font tags
        clean = re.sub(r"<[^>]+>", "", block)

        # Extract datetime
        dt_match = dt_pattern.search(clean)
        if not dt_match:
            continue
        dt_str = dt_match.group(1)
        try:
            dt = datetime.strptime(dt_str, "%Y-%m-%d %H:%M:%S.%f")
        except ValueError:
            dt = datetime.strptime(dt_str, "%Y-%m-%d %H:%M:%S")

        # Shift to UTC
        dt_utc = dt - timedelta(hours=tz_offset)

        # Extract telemetry fields
        fields = {k: v.strip() for k, v in field_pattern.findall(clean)}

        try:
            lat = float(fields["latitude"])
            lon = float(fields["longitude"])
        except (KeyError, ValueError):
            continue

        # Skip zero-coordinate frames (no GPS fix)
        if lat == 0.0 and lon == 0.0:
            continue

        # abs_alt and rel_alt share one bracket; extract them directly
        abs_m = abs_alt_pattern.search(clean)
        rel_m = rel_alt_pattern.search(clean)
        if abs_m:
            alt = float(abs_m.group(1))
        elif rel_m:
            alt = float(rel_m.group(1))
        else:
            alt = 0.0

        points.append({"time": dt_utc, "lat": lat, "lon": lon, "ele": alt})

    return points


def build_gpx(points: list[dict], source_name: str) -> str:
    gpx = ET.Element("gpx", {
        "version": "1.1",
        "creator": "DJI Avata 360",
        "xmlns": "http://www.topografix.com/GPX/1/1",
        "xmlns:xsi": "http://www.w3.org/2001/XMLSchema-instance",
        "xsi:schemaLocation": (
            "http://www.topografix.com/GPX/1/1 "
            "http://www.topografix.com/GPX/1/1/gpx.xsd"
        ),
    })

    # Metadata
    metadata = ET.SubElement(gpx, "metadata")
    if points:
        time_el = ET.SubElement(metadata, "time")
        time_el.text = points[0]["time"].strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"

        lats = [p["lat"] for p in points]
        lons = [p["lon"] for p in points]
        ET.SubElement(metadata, "bounds", {
            "minlat": f"{min(lats):.6f}",
            "minlon": f"{min(lons):.6f}",
            "maxlat": f"{max(lats):.6f}",
            "maxlon": f"{max(lons):.6f}",
        })

    # Track
    trk = ET.SubElement(gpx, "trk")
    name_el = ET.SubElement(trk, "name")
    name_el.text = "DJI GPS Data"
    trkseg = ET.SubElement(trk, "trkseg")

    for p in points:
        trkpt = ET.SubElement(trkseg, "trkpt", {
            "lat": f"{p['lat']:.9g}",
            "lon": f"{p['lon']:.9g}",
        })
        ele_el = ET.SubElement(trkpt, "ele")
        ele_el.text = f"{p['ele']:.3f}"
        time_el = ET.SubElement(trkpt, "time")
        time_el.text = p["time"].strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"

    # Pretty-print
    raw = ET.tostring(gpx, encoding="unicode")
    dom = minidom.parseString(raw)
    return dom.toprettyxml(indent="  ", encoding=None)


def main():
    parser = argparse.ArgumentParser(description="Convert DJI SRT telemetry to GPX.")
    parser.add_argument("-o", "--output", help="Output .gpx path (only valid with a single input file)")
    parser.add_argument(
        "--tz-offset",
        type=int,
        default=0,
        metavar="HOURS",
        help="Hours to subtract from SRT timestamps to get UTC (e.g. 1 for UTC+1)",
    )
    parser.add_argument("inputs", nargs="+", metavar="FILE", help="One or more .srt files")
    args = parser.parse_args()

    if args.output and len(args.inputs) > 1:
        sys.exit("Error: -o/--output can only be used with a single input file.")

    for input_path in args.inputs:
        srt_path = Path(input_path)
        if not srt_path.exists():
            print(f"Error: file not found: {srt_path}", file=sys.stderr)
            continue

        out_path = Path(args.output) if args.output else srt_path.with_suffix(".gpx")

        print(f"Parsing {srt_path} ...")
        points = parse_srt(srt_path, args.tz_offset)

        if not points:
            print(f"Error: no valid GPS points found in {srt_path}.", file=sys.stderr)
            continue

        print(f"Found {len(points)} GPS points.")
        gpx_content = build_gpx(points, srt_path.stem)

        out_path.write_text(gpx_content, encoding="utf-8")
        print(f"Written to {out_path}")


if __name__ == "__main__":
    main()
