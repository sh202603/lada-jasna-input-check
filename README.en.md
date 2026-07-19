# Check-VideoInput for lada-ex / jasna

[日本語](README.md) | **English**

Version: 1.2.0

A PowerShell tool that inspects videos before you feed them to [lada-ex](https://codeberg.org/comman/lada-ex) / [jasna](https://github.com/Kruk2/jasna).

It uses ffprobe / ffmpeg to examine a video's metadata, PTS/DTS, and bitstream, checking whether it matches both tools' requirements (container / codec / color space) and whether the PTS is broken (missing, negative, duplicate, going backward, or with large gaps). When a problem is found, it explains the cause and presents a **ready-to-copy-and-paste ffmpeg repair command**. (It can also write the repair commands out to a file.)

The goal is to catch videos that fail to process, end up out of sync, or have wrong colors — before you run the actual processing.

---

## When to use it

- A video stops with an error when fed into lada-ex / jasna
- Processing succeeded, but audio and video are out of sync / colors look wrong
- You want to find the problematic files first, before processing a large batch

---

## Quick start (for those new to GitHub or the command line)

You can get going in three steps. Follow them in order.

### Step 1: Get ffmpeg

This tool uses **ffmpeg / ffprobe** to inspect videos. First, check whether they are already installed.

1. Open "PowerShell" or "Terminal" from the Start menu.
2. Type the following and press Enter.

   ```powershell
   ffmpeg -version
   ```

3. If version information is shown, you are ready. Go to Step 2.

If you see something like "`ffmpeg` is not recognized", install it with one of the following.

**Easy method (Windows 11)** — run the following command.

```powershell
winget install Gyan.FFmpeg
```

After installing, **close and reopen the terminal**, then confirm again with `ffmpeg -version`.

**Manual method** — download a Windows build from [ffmpeg.org](https://ffmpeg.org/download.html), extract it, and add the `bin` folder (the one containing `ffmpeg.exe` / `ffprobe.exe`) to PATH. If setting PATH is difficult, you can use the `FFMPEG_BIN_DIR` approach described later instead.

### Step 2: Download this tool

**Easy method (download ZIP)**

1. Press the green **"Code"** button near the top of this page.
2. Choose **"Download ZIP"** from the menu.
3. Right-click the downloaded ZIP, choose "Extract All", and place it wherever you like (e.g. the desktop).

**Using git (for those who have git installed)**

```powershell
git clone https://github.com/sh202603/lada-jasna-input-check.git
```

### Step 3: Inspect a video

1. Open the extracted folder (the one containing `Check-VideoInput.ps1`).
2. Right-click an empty spot inside the folder and choose **"Open in Terminal"**.
3. In the window that opens, type the following and press Enter. Replace the `"..."` part with the path to the video you want to inspect (dragging and dropping a video file onto the window fills in the path automatically).

   In PowerShell (Terminal):

   ```powershell
   .\Check-VideoInput.ps1 "C:\Users\you\Videos\sample.mp4"
   ```

   From Command Prompt (cmd), use the bundled `Check-VideoInput.bat` (no execution-policy setup needed):

   ```bat
   Check-VideoInput.bat "C:\Users\you\Videos\sample.mp4"
   ```

4. After a short wait, the inspection results — and any repair commands if there is a problem — are shown.

> **If you want to use it from Command Prompt (cmd)**, or if PowerShell's execution policy blocks you, use the bundled `Check-VideoInput.bat`. It works without any execution-policy setup.
>
> ```bat
> Check-VideoInput.bat "C:\Users\you\Videos\sample.mp4"
> ```
>
> You can also drag and drop a video file onto `Check-VideoInput.bat` to inspect it, but the result window closes when it finishes. To read the results at your own pace, run it from a terminal as shown above.

### Reading the results

- **Verdict "OK"** … You can feed it to lada-ex / jasna as-is.
- **Verdict "WARN"** … It can be processed, but there are risks such as slowdown or audio desync. If it concerns you, run the repair command shown.
- **Verdict "NG"** … A problem was found that does not match the requirements, or the file may be broken. It will not necessarily fail, and if the issue is minor it may pass as-is. However, it may fail partway through, or the processed video may stutter / be out of sync / have wrong colors. To process it with confidence, we recommend fixing it with the shown repair command before feeding it in.

To inspect an entire folder at once, specify a folder path instead of a file path (add `-Recurse` to include subfolders).

```powershell
.\Check-VideoInput.ps1 "C:\Users\you\Videos" -Recurse
```

---

## Requirements

- Windows 11 (the supported target; Windows 10 is not supported — it may work but is untested)
- Windows PowerShell 5.1, or PowerShell 7 or later (either works)
- `ffprobe` / `ffmpeg` (used for inspection and to generate repair commands)

ffprobe / ffmpeg are searched for in this order:

1. The location explicitly given via `-FFprobePath` / `-FFmpegPath`
2. `ffmpeg` / `ffprobe` registered in PATH
3. The directory specified by the `FFMPEG_BIN_DIR` environment variable

Normally, having ffmpeg on PATH is enough. If you do not want it on PATH, set the `FFMPEG_BIN_DIR` environment variable to the folder containing ffmpeg / ffprobe (e.g. `C:\ffmpeg\bin`).

---

## Detailed usage

```powershell
.\Check-VideoInput.ps1 <file|folder> [options]

# examples
.\Check-VideoInput.ps1 D:\videos\sample.mp4
.\Check-VideoInput.ps1 D:\videos -Recurse -Target jasna -Level full
```

From Command Prompt (cmd), use `Check-VideoInput.bat`.

```bat
Check-VideoInput.bat D:\videos\sample.mp4 -Level full
```

This wrapper works as follows.

- It looks for PowerShell 7 (pwsh) with `where pwsh.exe`; if found it uses that, otherwise it uses the built-in powershell.exe (5.1).
- It launches `Check-VideoInput.ps1` (in the same folder) with `-NoProfile -ExecutionPolicy Bypass -File`, so no execution-policy setup is needed.
- It passes through the given arguments (`%*`) and the exit code (0/1/2) unchanged.

### Parameters

| Parameter | Values | Default | Description |
|---|---|---|---|
| `-Path` (position 0, required) | file or folder | — | Specifying a folder inspects all videos with target extensions at once |
| `-Target` | `lada` / `jasna` / `both` | `both` | The tool to judge against. Affects the verdict line, fixes, and exit code |
| `-Level` | `quick` / `standard` / `full` | `standard` | Inspection depth (see table below) |
| `-JasnaVersion` | `0.7.2` / `0.8.1` | `0.8.1` | The jasna version to judge against. jasna 0.8.1 moved its media layer to PyAV, which changed the input constraints substantially. Only meaningful when `-Target` is `jasna` or `both` |
| `-Segments` | switch | off | Adds the stricter checks that apply when jasna's `--segments` (smart rendering) is used. Only active on 0.8.1; a no-op on 0.7.2 |
| `-Lang` | `ja` / `en` / `auto` | `auto` | Display language. `auto` shows Japanese if the OS culture is Japanese, otherwise English (the verdict and exit code are language-independent) |
| `-Recurse` | switch | off | Also include subdirectories of the folder |
| `-FixScript` | output file path | — | Writes the shown repair commands to a single file you can run later as a batch (see below) |
| `-FFprobePath` / `-FFmpegPath` | path | auto-detect | Explicitly specify the location of ffprobe / ffmpeg |
| `-Version` | switch | — | Print the tool version and exit (no inspection; works even without ffmpeg / ffprobe) |

### Writing repair commands to a file (`-FixScript`)

Adding `-FixScript <output file>` writes the repair commands shown on screen into a single file. It collects them for every inspected file (all of them when multiple files / a folder is specified), which is handy when you want to review and then batch-run them in PowerShell.

```powershell
.\Check-VideoInput.ps1 D:\videos -Recurse -FixScript fixes.ps1
```

- The `ffmpeg ...` lines are written in a directly runnable form (with the real file paths). Problem descriptions (`# [PTS problem] ...`) and notes (`# Note: ...`) are written as `#` comments, so if you use a `.ps1` output it can run as a PowerShell script as-is.
- Each repaired video produced by an ffmpeg command becomes a `.mkv` (`<original name>_<suffix>.mkv`) regardless of the input extension (see [Why the output is always `.mkv`](#why-the-output-is-always-mkv)). The extension of the `-FixScript` output file itself can be anything.
- Separator comments (file name, metadata) are inserted per file. Files that needed no fixing are not included.
- **When one file has multiple fixes, the content is written so each produces a separate output file.** Running them all in order would create multiple repaired versions from the original, so before running, delete the unneeded lines and keep only the fixes you want.
- The output file is saved as UTF-8 (with BOM). Adding `-FixScript` does not change the on-screen output or the exit code.
  - This is so the generated script's comments do not break when run/edited in Windows PowerShell 5.1 (without a BOM, 5.1 misreads it as CP932).
  - **Be careful with editors that always open files as Shift_JIS (CP932).** Most editors auto-detect UTF-8 from the BOM or content, but if one reads it as Shift_JIS without detecting, characters break and the BOM may appear as garbage characters at the start of the first line. In that case, **reopen the file specifying UTF-8 encoding**.
  - Garbage characters are not limited to comments. **If an input file name contains non-ASCII characters, the `ffmpeg ...` command lines also contain those paths** (the input path and the output `<original name>_<suffix>.mkv`). Since the whole file is UTF-8 (with BOM), running it in PowerShell (5.1 or 7) passes the paths to ffmpeg correctly.
  - When you edit and **re-save, keep it as UTF-8.** If you re-save as Shift_JIS, PowerShell 7 (which reads it as the default UTF-8) will corrupt the paths and execution will fail. (PowerShell 5.1 reads it as CP932 so Shift_JIS works there, but UTF-8 is recommended to avoid environment differences.)

### Inspection levels

| Level | What it does | Rough speed |
|---|---|---|
| `quick` | ffprobe metadata + only the first packet (the same inspection scope as lada-ex itself) | a few seconds/file |
| `standard` (default) | quick + a full PTS/DTS scan of all packets (`ffprobe -show_entries packet=pts,dts`) | tens of seconds for a few GB |
| `full` | standard + decoding every frame for verification (`ffmpeg -v error -f null -`). Also detects bitstream corruption | a fraction of real time |

### Exit codes

| Code | Meaning |
|---|---|
| 0 | No problems relevant to the target tool |
| 1 | WARN only (processable, but with risks such as slowdown or desync) |
| 2 | FAIL present (may fail to process, or even if it processes may stutter / desync / have wrong colors), or a tool/path error |

When narrowed with `-Target`, findings specific to the excluded tool do not affect the exit code. Examples of chaining from a batch process:

- PowerShell: `pwsh -File Check-VideoInput.ps1 $file && lada-cli ...`
- cmd: `Check-VideoInput.bat "%file%" && lada-cli ...`

### Folder-scan target extensions

This is lada-ex's supported list plus common video extensions.

`.asf .avi .m4v .mkv .mov .mp4 .mpeg .mpg .ts .wmv .webm .rmvb .vob .3gp .flv .m2ts .mts`

(If you specify a single file, it is inspected regardless of its extension.)

---

## Inspection items

### Common (run in quick)

| # | Item | Verdict | Fix key |
|---|---|---|---|
| 1 | File size is 0 | FAIL | — |
| 2 | ffprobe fails to parse (container corruption) | FAIL | remux |
| 3 | No video stream | FAIL | — |
| 4 | Cannot determine frame rate (e.g. `r_frame_rate` denominator 0) | FAIL | remux |
| 5 | Cannot determine duration | WARN | remux |
| 6 | Cannot determine resolution | FAIL | — |
| 7 | Possible VFR (`r_frame_rate` and `avg_frame_rate` differ by more than 1%) | WARN | vfr |
| 8 | Interlaced (`field_order` other than progressive/unknown) | WARN | interlace |
| 9 | First packet PTS is N/A (the broken-AVI pattern) | FAIL | genpts |
| 10 | Cannot read the first packet | FAIL | remux |

### Added in standard (full packet scan)

Parses the pts/dts of every packet in the video stream via a CSV stream.

| Item | Verdict | Rationale |
|---|---|---|
| Packets with no PTS | FAIL | Frame times cannot be determined, breaking AV sync |
| Negative-PTS packets (2 or more) | WARN | Causes a missing head / desync |
| Duplicate PTS | FAIL | Same-time frames mixed in = bad mux (a few often pass, many cause stutter/desync) |
| DTS going backward | FAIL | Breaks decode order; seeking/decoding becomes unstable |
| Large PTS gap after sorting | WARN (lada) | A known cause of AV desync in lada-ex |

The large-gap threshold is `max(median frame interval × 4, 0.5 s)`. PTS is normally non-monotonic because of B-frames, so monotonicity is judged on DTS, and PTS is judged on the gap after sorting.

### Added in full (decode verification)

Runs `ffmpeg -v error -i <file> -map 0:v:0 -f null -`, and if there is any error output, marks it FAIL (showing the count and the first 3).

### lada-ex-specific judgments

| Item | Verdict | Rationale |
|---|---|---|
| Extension outside the whitelist | FAIL | Not in lada-ex's supported extension list |
| `first_pts < -1000` | WARN | Forced to VAAPI to avoid an Intel QSV driver crash |
| `first_pts < 0` / `start_time < 0` | WARN | Triggers a TorchCodec → PyAV fallback (slower) |
| `time_base == 1/10000000` | WARN | Incompatible with TorchCodec exact seek, so it falls back to PyAV |
| `color_range` unknown | WARN | Falls back to PyAV when it cannot be inferred |
| VFR + large PTS gap | WARN | A known cause of AV desync |

### jasna-specific judgments

jasna 0.8.1 replaced its media layer wholesale (python_vali/PyNvVideoCodec → **PyAV**), which changed the input constraints substantially. `-JasnaVersion` selects which set of criteria to apply (default `0.8.1`).

| Item | 0.7.2 | 0.8.1 | Rationale |
|---|---|---|---|
| Codec other than h264/hevc/vp9/av1 | **FAIL** | WARN | 0.7.2 requires NVDEC and cannot process it. 0.8.1 falls back to CPU decoding automatically, so the only cost is speed |
| `color_space` not recognized | WARN | WARN | 0.8.1 added BT.2020 support. **In both versions an unknown tag is silently coerced to BT.709 rather than raising**, so the real cost is shifted colors, not a crash |
| `color_space` not set | WARN | WARN | Same as above (silently treated as BT.709) |
| Odd width or height | — | **FAIL** | 0.8.1's NV12 conversion requires even dimensions and aborts **after encoding has started** |
| `duration` unavailable | **FAIL** | **FAIL** | Aborts with a `KeyError` while reading metadata |
| `start_pts` missing | WARN | WARN | The GUI preview aborts with a `TypeError` (CLI runs still work) |
| HDR (PQ / HLG) | WARN | WARN | No tone mapping; the transfer characteristics pass straight through, so output is blown out or crushed |
| Interlaced | WARN | WARN | jasna does not deinterlace |
| Chroma other than 4:2:0 (4:2:2 / 4:4:4 / RGB) | WARN | WARN | Subsampled to 4:2:0, losing color resolution |
| Bit depth above 10-bit | WARN | WARN | Reduced to 10-bit |
| Negative-PTS packets | WARN | WARN | 0.7.2 drops them (missing head). 0.8.1 keeps them and shifts the origin to 0 |
| Subtitle / data / attachment / chapter streams | WARN | WARN | Lost in the output (only the first video stream plus audio are muxed) |
| Multiple video streams | WARN | WARN | Only the first one is processed |
| Audio packets without PTS/DTS | WARN | WARN | Those packets are dropped (checked at `standard` and above) |
| Extension outside the folder-scan list | WARN | WARN | jasna's folder scan only covers `.mp4 .mkv .avi .mov .wmv .flv .webm`. Passing the file individually still works (detected only for folder input) |

> Because a missing `duration` is now a FAIL, files that previously exited with code 1 may now exit with 2.

### Extra checks for `--segments` (`-Segments`)

jasna's `--segments` (smart rendering) is far stricter than the normal path, and failing a gate means the job is **rejected** rather than falling back to a full re-encode. `-Segments` adds the following checks (all FAIL except the output-container item, which is WARN).

| Item | Requirement |
|---|---|
| Codec | `h264` / `hevc` / `av1` only |
| `pix_fmt` | `yuv420p` / `yuvj420p` / `nv12` / `yuv420p10le` / `p010le` only |
| Interlacing | Progressive only |
| 10-bit H.264 | Not supported |
| H.264 profile | `baseline` / `constrained baseline` / `main` / `high` only |
| Frame rate | CFR required (`r_frame_rate` and `avg_frame_rate` within 0.1% — stricter than the common VFR check) |
| Input extension | Output containers are limited to `.mp4` / `.mov` / `.mkv`, so anything else requires specifying the output extension explicitly |

0.7.2 has no `--segments` at all, so combining `-Segments` with `-JasnaVersion 0.7.2` adds nothing.

---

## Example output

Each file is shown like this.

```
Checking 1 file(s) / Target=both / Level=quick
jasna spec version: 0.8.1

=== sample.mp4 ===
  Metadata: mp4 / h264 / 1921x1080 / yuv420p / 29.97fps / 0:12:34 / audio: aac
  [WARN] (lada-ex) Negative start PTS (first_pts=-2002). ...
  [FAIL] (jasna 0.8.1) Odd width or height (1921x1080). jasna requires even dimensions for NV12 conversion ...
  Verdict: lada-ex → WARN / jasna 0.8.1 → NG

  --- Fixes ---
  [PTS problem] Regenerate PTS and remux to mkv (lossless, fast):
    ffmpeg -fflags +genpts -i "..." -map 0 -map -0:d -c copy -avoid_negative_ts make_zero "..._fixed.mkv"
```

- The verdict is `NG` if there is any FAIL, `WARN` if WARN only, and `OK` if nothing.
- Scope labels are not added to common items; tool-specific items get `(lada-ex)` / `(jasna <version>)`. Since jasna's criteria depend on the version, the label and the verdict line both show which version was used.
- When multiple files are inspected, a summary is shown at the end (one line per file with the lada-ex / jasna verdicts, file name, and main problem). Verdicts are color-coded: NG=red / WARN=yellow / OK=green.
- Repair commands are generated with the real file paths, and the output is `<original name>_<suffix>.mkv` (in the same folder).

---

## Repair command list

| Key | Target problem | What is presented | Quality loss |
|---|---|---|---|
| genpts | Missing/negative/duplicate PTS, backward DTS | Remux to mkv with `-fflags +genpts ... -c copy -avoid_negative_ts make_zero` | lossless |
| remux | Container corruption, unsupported extension, missing metadata | Remux to mkv with `-c copy` (with an `-err_detect ignore_err` note) | lossless |
| jasna_reencode | jasna-unsupported codec (0.7.2), codec unsupported by `--segments` | Re-encode with `hevc_nvenc`. Adds `-vf bwdif` automatically when interlacing is detected | re-encode |
| jasna_reencode_speed | Codec outside jasna 0.8.1's hardware-decode set | Same as above, but notes that processing still works so the fix is **optional** | re-encode |
| even_dims | Odd width or height | Crop to even dimensions with `crop=trunc(iw/2)*2:trunc(ih/2)*2` and re-encode (padding alternative noted) | re-encode |
| pixfmt_420 | Chroma other than 4:2:0, excess bit depth | Convert to 8-bit 4:2:0 with `-vf format=yuv420p` and re-encode | re-encode |
| color_convert | HDR (PQ / HLG) sources | Convert to BT.709 with zscale + tonemap (with a lighter variant noted for SDR sources) | re-encode |
| color_tag | Missing color space tag | For h264/hevc, lossless tag writing via the `*_metadata` bsf (BT.601 values also noted). For other codecs, no action if the guess is fine, re-encode only when needed | codec-dependent |
| range_tag | Unknown color range | For h264/hevc, write `video_full_range_flag=0` via bsf. Otherwise a re-encode suggestion | codec-dependent |
| vfr | VFR / large PTS gap | A note that remux won't fix it, plus a `-fps_mode cfr` re-encode suggestion (with a note to try as-is first) | re-encode |
| interlace | Interlaced | Deinterlace with `-vf bwdif` and re-encode | re-encode |
| reencode_broken | Bitstream corruption | Skip broken parts with `-err_detect ignore_err` and re-encode (with a note recommending re-obtaining the source) | re-encode |

Even if there are multiple problems with the same fix key, the command is presented only once (deduplicated). For problems specific to a tool excluded by `-Target`, no fix is shown.

### Why the output is always `.mkv`

The repair command output (and the ffmpeg commands written by `-FixScript`) is always `.mkv` (Matroska) regardless of the input extension, because using the same extension as the input sometimes does not constitute a repair / fails.

- **Unsupported extensions are themselves a repair target**: when the extension is outside lada-ex's support (e.g. `.flv`), emitting the same extension keeps it unsupported. `.mkv` is supported by both lada-ex / jasna.
- **mkv is the most lenient**: putting a stream rebuilt with `+genpts` / `-avoid_negative_ts make_zero` (for negative PTS, missing PTS, unusual time_base, etc.) back into mp4 tends to hit constraints and recur/fail, whereas mkv stores it cleanly.
- **Codec-agnostic**: even containers that cannot properly hold HEVC (`.avi` / `.wmv` / `.vob`, etc.) fit into mkv reliably.

Note that repair commands that copy all streams with `-map 0` also use `-map -0:d` to exclude data streams (e.g. mp4 `bin_data` chapter text). Matroska can only hold audio/video/subtitles, and including a data stream fails header generation with `Only audio, video, and subtitles are supported for Matroska`. `-map -0:d` is harmless on files with no data stream.

---

## Known limitations

- The standard full-packet scan does not decode, so it cannot detect image corruption (bitstream corruption). To detect it, use the full level.
- It does not validate the resolution / aspect ratio of VR material (VR180/VR360/TAB) (lada-ex has no such validation logic either).
- Beyond showing the codec name, audio is only checked at `standard` and above for packets that have neither PTS nor DTS (jasna drops those). Container-incompatible audio is re-encoded to AAC by jasna automatically, so no pre-check is needed.
- The judgment criteria are based on lada-ex / jasna's requirements at the time of investigation. When the tools' specs change, the constants at the top of the script need review (for jasna, the version-keyed `$JasnaSpecs` table).
- `-JasnaVersion` only offers the versions that have been investigated (0.7.2 / 0.8.1). For other versions, pick whichever behaves more closely.

---

## Development notes (PowerShell 5.1 / 7 compatibility constraints)

Points for those modifying this tool.

- Save `Check-VideoInput.ps1` as **UTF-8 (with BOM)**. Without a BOM, PowerShell 5.1 misreads it as CP932 and breaks the Japanese literals.
- Write `Check-VideoInput.bat` in **ASCII only**. cmd reads `.bat` files in the OEM codepage, so UTF-8 Japanese comments break the parser.
- Keep ffprobe / ffmpeg calls in the pattern of "switch `$ErrorActionPreference = "Continue"` locally and collect ErrorRecords with `2>&1`". PowerShell 5.1, left at `Stop`, halts with NativeCommandError when redirecting a native command's stderr.

---

## License

Released under the [MIT License](LICENSE).

References for the judgment criteria (both public projects):

- lada-ex: <https://codeberg.org/comman/lada-ex>
- jasna: <https://github.com/Kruk2/jasna>
