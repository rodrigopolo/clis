# Rodrigo Polo's CLIs

Multiple command line utilities and scripts for the daily use.

* To be placed in `~/.local/bin`
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
* For video encoding
  * `ToHEVCAndResize.sh`: Encodes to HEVC if isn't already encoded, and if it is bigger than 1280x720.
  * `encoding_test.sh`: Tests different presets and CRF values, capturing performance metrics.
  * `analyze_quality.sh`: Analyzes encoded videos against original using VMAF, SSIM, PSNR, and MS-SSIM.


Symbolic links
```sh
ln -s /opt/homebrew/bin/yt-dlp ~/.local/bin/youtube-dl
ln -s /Applications/MAMP/bin/php/php8.2.0/bin/php ~/.local/bin/php
ln -s /Applications/MAMP/Library/bin/mysql ~/.local/bin/mysql
ln -s /Applications/MAMP/Library/bin/mysqldump ~/.local/bin/mysqldump
ln -s /Applications/Sublime\ Text.app/Contents/SharedSupport/bin/subl ~/.local/bin/sublime
```
