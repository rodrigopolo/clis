# Local Bin

* `label`: To set a color label to a file in macOS.
* `pdirs`: To only show dirs on a piped list of files.
* `tmuxkillall`: To kill all `tmux` sessions.
* `minfo`: To get an ASCII summary of a media file.
* `minfo_template.txt`: `minfo` template.
* `getlocation`: Get latitude and longitude of images.
* `setlocation`: Set latitude and longitude to images.
* `srts`: Convert to UTF-8 and add uppercase after `¿` and `¡` to SRSs (Python).
* `tsd`: Twitter/X Space downloader
* `yd`: A `yt-dlp` wrapper.
* `ydc`: A `yt-dlp` wrapper to use cookies.
* `ydtw`: A `yt-dlp` wrapper for Twitter/X videos.
* `ydtwc`: A `yt-dlp` wrapper for Twitter/X videos with cookies.


Optional symbolic links
```sh
ln -s /Applications/MAMP/bin/php/php8.2.0/bin/php ~/.local/bin/php
ln -s /Applications/MAMP/Library/bin/mysql ~/.local/bin/mysql
ln -s /Applications/MAMP/Library/bin/mysqldump ~/.local/bin/mysqldump
ln -s /Applications/Sublime\ Text.app/Contents/SharedSupport/bin/subl ~/.local/bin/sublime
```

## extract_insv_gps

Extract GPS tracks from **Antigravity A1** (and Insta360-based) `.insv` video
files entirely from the command line — no proprietary app required.

---

### Requirements

- Python **3.8 or newer**
- No third-party packages — uses only the standard library

---

### Quick Start

```bash
## Single file → recording.extracted.gpx (alongside the input)
python3 extract_gps.py recording.insv

## Batch — process every .insv in a folder
python3 extract_gps.py /path/to/flights/*.insv
```

---

### Usage

```
python3 extract_gps.py [options] <file1.insv> [file2.insv …]
```

Output is always written alongside each input file as `<stem>.extracted.<format>`.

#### Arguments

| Flag           | Default | Description                                        |
| -------------- | ------- | -------------------------------------------------- |
| `file.insv …`  | *(required)* | One or more `.insv` input files               |
| `--format`     | `gpx`   | Output format: `gpx`, `kml`, or `csv`              |
| `--smooth`     | off     | Apply Kalman smoothing filter                      |
| `--smooth-q Q` | `1e-9`  | Process noise variance (smaller = more smoothing)  |
| `--smooth-r R` | `1e-8`  | Measurement noise variance                         |

#### Examples

```bash
## Single file → VID_….extracted.gpx alongside input
python3 extract_gps.py VID_20250920_101019_014.insv

## KML output → VID_….extracted.kml
python3 extract_gps.py --format kml VID_20250920_101019_014.insv

## CSV output → VID_….extracted.csv
python3 extract_gps.py --format csv VID_20250920_101019_014.insv

## Multiple files — each output written alongside its input
python3 extract_gps.py flight1.insv flight2.insv flight3.insv

## Batch
python3 extract_gps.py *.insv

## Smoothed output (approximates Antigravity Studio app export)
python3 extract_gps.py --smooth VID_20250920_101019_014.insv

## Batch with smoothing
python3 extract_gps.py --smooth *.insv

## Smoother (more lag) — useful for very noisy GPS
python3 extract_gps.py recording.insv --smooth --smooth-q 1e-11 --smooth-r 1e-8

## Less smoothing (faster response to direction changes)
python3 extract_gps.py recording.insv --smooth --smooth-q 1e-7 --smooth-r 1e-6
```

---

### Output Formats

#### GPX 1.1

Standard GPS Exchange Format — compatible with Google Earth, QGIS, Garmin devices, and most GPS tools. The `<time>` element is omitted when the GPS receiver had no valid timestamp lock (e.g. very short clips).

```xml
<?xml version="1.0" encoding="UTF-8"?>
<gpx version="1.1" creator="extract_gps.py" xmlns="http://www.topografix.com/GPX/1/1">
  <trk>
    <trkseg>
      <trkpt lat="14.5604016" lon="-90.7342367">
        <ele>1567.34</ele>
        <time>2026-05-19T16:10:24Z</time>
      </trkpt>
      …
    </trkseg>
  </trk>
</gpx>
```

#### KML 2.2

Compatible with Google Earth, Google Maps, and any OGC KML viewer. Outputs a single `<LineString>` with `altitudeMode=absolute`.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<kml xmlns="http://www.opengis.net/kml/2.2">
  <Document>
    <name>VID_20250920_101019_014</name>
    …
    <Folder>
      <name>Tracks</name>
      <Placemark>
        <LineString>
          <altitudeMode>absolute</altitudeMode>
          <coordinates>
             -90.7342367,14.5604016,1567.34
             …
          </coordinates>
        </LineString>
      </Placemark>
    </Folder>
  </Document>
</kml>
```

#### CSV

```
timestamp_utc,latitude,longitude,elevation_m
2026-05-19T16:10:24Z,14.5604016,-90.7342367,1567.34
2026-05-19T16:10:26Z,14.5604016,-90.7342367,1567.30
…
```

---

### Smoothing

#### Raw vs smoothed

The GPS receiver in the Antigravity A1 outputs raw position fixes at roughly 0.5–1 Hz. These raw measurements contain the typical noise of a consumer GNSS chip (±2–10 m). The Antigravity Studio app applies a **Kalman smoothing filter** before exporting `.gpx` files.

| Mode              | Characteristics                                                              |
| ----------------- | ---------------------------------------------------------------------------- |
| **Raw** (default) | True GPS receiver output; most accurate for mapping; may appear jittery      |
| **`--smooth`**    | Kalman-filtered; matches app export to within ~15 m; visually cleaner tracks |

#### How the Kalman filter works

A 1-D constant-position Kalman filter is applied independently to latitude, longitude, and elevation:

```
Each step:
  Predict:  P  ← P + q        (uncertainty grows between measurements)
  Gain:     K  = P / (P + r)  (how much to trust the new measurement)
  Update:   x  ← x + K·(z−x) (blend previous estimate with new reading)
            P  ← (1−K)·P
```

#### Tuning Q and R

The `q/r` ratio controls the smoothing strength:

| Ratio `q/r`   | Effect                                                |
| ------------- | ----------------------------------------------------- |
| Small (< 0.1) | Heavy smoothing, noticeable lag during sharp turns    |
| Medium (~0.1) | Default — matches app output for typical drone flight |
| Large (> 1.0) | Light smoothing, faster response, less lag            |

**Rule of thumb:** halving `q` doubles the smoothing; doubling `r` also increases smoothing.

---

### How It Works

The `.insv` file is a standard **MP4 container** with a proprietary **Insta360 binary trailer** appended after the last MP4 box. Standard metadata tools (`exiftool`, `ffprobe`, `mediainfo`) do not see the GPS data because it lives outside the MP4 structure.

**Trailer location:**
- The last 32 bytes of the file are the ASCII magic string `8db42d694ccc418790edff439fe026bf`
- The 4-byte little-endian uint32 at offset `−40` from EOF gives the trailer size

**GPS record format** (53 bytes, little-endian):
```
[0]      0x41   record marker
[1:9]    double latitude  (positive; direction in byte 9)
[9]      'N' or 'S'
[10:18]  double longitude (positive absolute; direction in byte 18)
[18]     'E' or 'W'
[19:35]  speed + bearing  (16 bytes, two doubles)
[35:43]  double elevation (metres)
[43:47]  uint32 Unix timestamp (seconds UTC)
[47:53]  6 bytes padding
```

The GPS section is located by scanning the trailer for this record pattern — no hardcoded offsets are used, making the script compatible with any recording length.

For full reverse-engineering details see [`RESEARCH.md`](RESEARCH.md).

---

### Files in This Repository

| File                           | Description                                                                                     |
| ------------------------------ | ----------------------------------------------------------------------------------------------- |
| `extract_gps.py`               | GPS extraction script (this tool)                                                               |
| `RESEARCH.md`                  | Full reverse-engineering notes: tools tried, binary format analysis, comparison with app output |
| `VID_20250920_101019_014.insv` | Sample Antigravity A1 recording (not included in repo)                                          |
| `VID_20250920_101019_014.gpx`  | Reference GPX exported by Antigravity Studio app (127-point flight)                             |
| `VID_20250920_101524_015.insv` | Sample short (2 s) accidental clip (not included in repo)                                       |
| `VID_20250920_101524_015.gpx`  | Reference GPX exported by Antigravity Studio app (1-point clip)                                 |
