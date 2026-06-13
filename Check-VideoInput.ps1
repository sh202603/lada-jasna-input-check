#Requires -Version 5.1
# Check-VideoInput.ps1 — lada-ex / jasna 入力ファイル事前チェッカー
#
# lada-ex / jasna に投入する前に、入力動画が両ツールの仕様に合っているか、
# PTS などの壊れが無いかを ffprobe/ffmpeg で検査する。問題があれば
# 原因と具体的な修復コマンド (コピペ実行可能) を提示する。
#
# Windows PowerShell 5.1 / PowerShell 7+ 両対応。
# ※ このファイルは UTF-8 (BOM 付き) で保存すること (BOM が無いと 5.1 が CP932 として誤読し日本語が壊れる)
#
# 使い方:
#   .\Check-VideoInput.ps1 <ファイル|フォルダ>
#   .\Check-VideoInput.ps1 D:\videos -Recurse -Target jasna -Level full
#   Check-VideoInput.bat <ファイル|フォルダ>   (cmd から。pwsh → powershell.exe の順で自動選択)
#
# チェックレベル:
#   quick    : ffprobe メタデータ + 先頭パケットのみ (数秒)
#   standard : quick + 全パケット PTS/DTS スキャン (既定。数GB で数十秒)
#   full     : standard + 全フレームデコード検証 (最も確実。実時間の数分の一)
#
# 終了コード: 0=全て OK / 1=WARN あり / 2=FAIL あり
#
# 判定根拠 (各ツール main ブランチのソース調査による):
#   lada-ex : lada/utils/video_utils.py — 拡張子ホワイトリスト、first_pts<0 や
#             time_base=1/10000000 で TorchCodec→PyAV フォールバック (低速化)、
#             first_pts<-1000 で QSV クラッシュ回避、VFR 大ギャップで AV 同期ずれ
#   jasna   : NVDEC 前提のため入力コーデックは h264/hevc/vp9/av1 のみ。
#             色空間は BT.709/BT.601 のみ (pipeline.py で UnsupportedColorspaceError)。
#             負の PTS のフレームはデコード時に黙って捨てられる

[CmdletBinding(DefaultParameterSetName="Check")]
param(
  [Parameter(ParameterSetName="Check", Mandatory=$true, Position=0)]
  [string]$Path,

  [ValidateSet("lada", "jasna", "both")]
  [string]$Target = "both",

  [ValidateSet("quick", "standard", "full")]
  [string]$Level = "standard",

  [switch]$Recurse,

  [string]$FFprobePath,
  [string]$FFmpegPath,

  [string]$FixScript,

  # バージョンを表示して終了する (検査は行わない)
  [Parameter(ParameterSetName="Version", Mandatory=$true)]
  [switch]$Version
)

$ErrorActionPreference = "Stop"

# ツールのバージョン。リリースごとに更新する
$ToolVersion = "1.0.1"

# -Version: ffprobe/ffmpeg の検出より前に処理する (ツール未導入でも表示できるように)
if ($Version) {
  Write-Host "Check-VideoInput $ToolVersion"
  exit 0
}

# --- ffprobe / ffmpeg の自動検出 ---
# 優先順位: -FFprobePath/-FFmpegPath で明示指定 → PATH → 環境変数 FFMPEG_BIN_DIR
# 環境変数を設定しない場合は PATH 上の ffmpeg/ffprobe を使う (通常はこれで十分)。
function Find-Tool([string]$Name, [string]$Override) {
  if ($Override) {
    if (Test-Path $Override) { return $Override }
    Write-Host "ERROR: 指定された $Name が見つかりません: $Override" -ForegroundColor Red
    exit 2
  }
  $candidates = @(
    (Get-Command $Name -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source)
  )
  if ($env:FFMPEG_BIN_DIR) {
    $candidates += (Join-Path $env:FFMPEG_BIN_DIR "$Name.exe")
  }
  foreach ($c in $candidates) {
    if ($c -and (Test-Path $c)) { return $c }
  }
  Write-Host "ERROR: $Name が見つかりません。PATH に追加するか、環境変数 FFMPEG_BIN_DIR で ffmpeg/ffprobe の置き場所を指定するか、-${Name}Path で明示してください" -ForegroundColor Red
  exit 2
}

$FFprobe = Find-Tool "ffprobe" $FFprobePath
$FFmpeg  = Find-Tool "ffmpeg"  $FFmpegPath

# --- 仕様定数 ---
# lada-ex の対応拡張子 (lada/utils/video_utils.py の VIDEO_EXTENSIONS)
$LadaExtensions = @(".asf", ".avi", ".m4v", ".mkv", ".mov", ".mp4", ".mpeg",
                    ".mpg", ".ts", ".wmv", ".webm", ".rmvb", ".vob", ".3gp")
# ディレクトリ走査時の対象 (lada 対応 + 一般的な動画拡張子)
$ScanExtensions = $LadaExtensions + @(".flv", ".m2ts", ".mts")
# jasna が NVDEC でデコードできるコーデック
$JasnaCodecs = @("h264", "hevc", "vp9", "av1")
# jasna が対応する色空間 (BT.709 / BT.601)
$JasnaColorspaces = @("bt709", "smpte170m", "bt470bg")

# --- 検査結果オブジェクト ---
function New-CheckResult([System.IO.FileInfo]$File) {
  [PSCustomObject]@{
    File     = $File
    MetaLine = ""
    Codec    = ""
    Findings = [System.Collections.Generic.List[object]]::new()  # Severity/Scope/Message/FixKey
    Failed   = $false   # ffprobe 自体が失敗 (メタデータ無し)
  }
}

function Add-Finding($Result, [string]$Severity, [string]$Scope, [string]$Message, [string]$FixKey = "") {
  $Result.Findings.Add([PSCustomObject]@{
    Severity = $Severity   # WARN / FAIL
    Scope    = $Scope      # common / lada / jasna
    Message  = $Message
    FixKey   = $FixKey
  })
}

# --- ffprobe 実行ヘルパ (stderr をメッセージとして回収) ---
# PS5.1 は $ErrorActionPreference=Stop のまま native の stderr をリダイレクトすると
# 1 行目で NativeCommandError として停止する。関数ローカルで Continue に切り替え、
# 2>&1 で merge した上で ErrorRecord (stderr 行) と文字列 (stdout 行) に振り分ける
function Invoke-FFprobeJson([string[]]$ProbeArgs) {
  $ErrorActionPreference = "Continue"
  # ffprobe/ffmpeg は stdout/stderr を常に UTF-8 で出力する。一方 PowerShell は
  # native の出力を [Console]::OutputEncoding で復号するため、日本語 Windows 既定の
  # CP932 のままだと JSON 内の日本語タグ (artist 等) が壊れ ConvertFrom-Json が失敗する。
  # 取得の間だけ UTF-8 に切り替え、finally で必ず元に戻す (利用者のコンソール設定を汚さない)
  $prevEnc = [Console]::OutputEncoding
  try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $merged = & $FFprobe -v error -print_format json @ProbeArgs 2>&1
  } finally { [Console]::OutputEncoding = $prevEnc }
  $exitCode = $LASTEXITCODE
  $outLines = [System.Collections.Generic.List[string]]::new()
  $errLines = [System.Collections.Generic.List[string]]::new()
  foreach ($item in $merged) {
    if ($item -is [System.Management.Automation.ErrorRecord]) { $errLines.Add($item.Exception.Message) }
    else { $outLines.Add([string]$item) }
  }
  $stderr = ($errLines -join " / ").Trim()
  $jsonText = ($outLines -join "`n").Trim()
  if ($exitCode -ne 0 -or -not $jsonText) {
    return [PSCustomObject]@{ Ok = $false; Json = $null; Stderr = $stderr }
  }
  return [PSCustomObject]@{ Ok = $true; Json = ($jsonText | ConvertFrom-Json); Stderr = $stderr }
}

function ConvertFrom-Rational([string]$s) {
  # "30000/1001" → double。無効 (0/0 等) なら $null
  if (-not $s) { return $null }
  $parts = $s -split "/"
  if ($parts.Count -eq 2) {
    $num = [double]$parts[0]; $den = [double]$parts[1]
    if ($den -eq 0) { return $null }
    return $num / $den
  }
  try { return [double]$s } catch { return $null }
}

function Format-Duration([double]$Seconds) {
  if ($Seconds -le 0) { return "?" }
  return [TimeSpan]::FromSeconds($Seconds).ToString("h\:mm\:ss")
}

# =====================================================================
# ファイル 1 本の検査
# =====================================================================
function Test-VideoFile([System.IO.FileInfo]$File) {
  $r = New-CheckResult $File
  $p = $File.FullName

  # --- 存在・サイズ ---
  if ($File.Length -eq 0) {
    Add-Finding $r "FAIL" "common" "ファイルサイズが 0 バイト"
    $r.Failed = $true
    return $r
  }

  # --- ffprobe メタデータ ---
  $probe = Invoke-FFprobeJson @("-show_format", "-show_streams", $p)
  if (-not $probe.Ok) {
    Add-Finding $r "FAIL" "common" "ffprobe がファイルを解析できません (コンテナ破損の可能性): $($probe.Stderr)" "remux"
    $r.Failed = $true
    return $r
  }
  $fmt = $probe.Json.format
  $vStream = $probe.Json.streams |
    Where-Object { $_.codec_type -eq "video" -and $_.disposition.attached_pic -ne 1 } |
    Select-Object -First 1
  $aStream = $probe.Json.streams | Where-Object { $_.codec_type -eq "audio" } | Select-Object -First 1

  if (-not $vStream) {
    Add-Finding $r "FAIL" "common" "映像ストリームがありません"
    $r.Failed = $true
    return $r
  }

  $codec    = $vStream.codec_name
  $r.Codec  = $codec
  $width    = [int]$vStream.width
  $height   = [int]$vStream.height
  $pixFmt   = if ($vStream.pix_fmt) { $vStream.pix_fmt } else { "?" }
  $fps      = ConvertFrom-Rational $vStream.r_frame_rate
  $avgFps   = ConvertFrom-Rational $vStream.avg_frame_rate
  $timeBase = $vStream.time_base
  $tbVal    = ConvertFrom-Rational $timeBase
  $duration = 0.0
  if ($vStream.duration -and "$($vStream.duration)" -ne "N/A") { $duration = [double]$vStream.duration }
  elseif ($fmt.duration -and "$($fmt.duration)" -ne "N/A")     { $duration = [double]$fmt.duration }
  $colorSpace = $vStream.color_space
  $colorRange = $vStream.color_range
  $fieldOrder = $vStream.field_order
  $startTime  = $null
  if ($null -ne $vStream.start_time -and $vStream.start_time -ne "N/A") { $startTime = [double]$vStream.start_time }

  $audioDesc = if ($aStream) { $aStream.codec_name } else { "なし" }
  $fpsDesc = if ($fps) { "{0:0.###}fps" -f $fps } else { "fps不明" }
  $r.MetaLine = "$($File.Extension.TrimStart('.')) / $codec / ${width}x${height} / $pixFmt / $fpsDesc / $(Format-Duration $duration) / 音声: $audioDesc"

  # --- 基本メタデータの妥当性 ---
  if (-not $fps -or $fps -le 0) {
    Add-Finding $r "FAIL" "common" "フレームレートが取得できません (r_frame_rate=$($vStream.r_frame_rate))" "remux"
  }
  if ($duration -le 0) {
    Add-Finding $r "WARN" "common" "duration が取得できません (コンテナのインデックス欠落の可能性)" "remux"
  }
  if ($width -le 0 -or $height -le 0) {
    Add-Finding $r "FAIL" "common" "解像度が取得できません"
  }

  # --- VFR 検出 ---
  if ($fps -and $avgFps -and $avgFps -gt 0) {
    $diff = [math]::Abs($fps - $avgFps) / $fps
    if ($diff -gt 0.01) {
      Add-Finding $r "WARN" "common" ("VFR (可変フレームレート) の可能性: r_frame_rate={0:0.###} と avg_frame_rate={1:0.###} が不一致" -f $fps, $avgFps) "vfr"
    }
  }

  # --- インターレース ---
  if ($fieldOrder -and $fieldOrder -notin @("progressive", "unknown")) {
    Add-Finding $r "WARN" "common" "インターレース素材 (field_order=$fieldOrder)。検出/復元精度が落ちるためデインターレース推奨" "interlace"
  }

  # --- 色空間 / 色レンジ ---
  if (-not $colorSpace -or $colorSpace -eq "unknown") {
    Add-Finding $r "WARN" "jasna" "color_space 未設定。jasna は解像度から BT.709/601 を推定するが、推定が外れると色がずれる" "color_tag"
  } elseif ($colorSpace -notin $JasnaColorspaces) {
    Add-Finding $r "FAIL" "jasna" "color_space=$colorSpace — jasna は BT.709/BT.601 のみ対応 (UnsupportedColorspaceError で停止する)" "color_convert"
  }
  if (-not $colorRange -or $colorRange -eq "unknown") {
    Add-Finding $r "WARN" "lada" "color_range 不明。lada-ex は推定不能時 TorchCodec→PyAV フォールバック (低速化)" "range_tag"
  }

  # --- lada-ex: 拡張子 ---
  if ($File.Extension.ToLower() -notin $LadaExtensions) {
    Add-Finding $r "FAIL" "lada" "拡張子 $($File.Extension) は lada-ex の対応リスト外" "remux"
  }

  # --- jasna: コーデック ---
  if ($codec -notin $JasnaCodecs) {
    Add-Finding $r "FAIL" "jasna" "コーデック $codec は jasna (NVDEC) 非対応 — 対応は h264/hevc/vp9/av1 のみ" "jasna_reencode"
  }

  # --- lada-ex: time_base ---
  if ($timeBase -eq "1/10000000") {
    Add-Finding $r "WARN" "lada" "time_base=1/10000000 は TorchCodec exact seek 非互換 → PyAV フォールバック (低速化)" "remux"
  }

  # --- 先頭パケット PTS ---
  $pkt = Invoke-FFprobeJson @("-select_streams", "v:0", "-show_packets", "-read_intervals", "%+#1", $p)
  $firstPts = $null
  if ($pkt.Ok -and $pkt.Json.packets -and $pkt.Json.packets.Count -gt 0) {
    $rawPts = $pkt.Json.packets[0].pts
    if ($null -eq $rawPts -or "$rawPts" -eq "N/A") {
      Add-Finding $r "FAIL" "common" "先頭パケットの PTS がありません (壊れた AVI などのパターン。フレームのタイムスタンプが信頼できない)" "genpts"
    } else {
      $firstPts = [long]$rawPts
    }
  } else {
    Add-Finding $r "FAIL" "common" "先頭パケットを読み取れません (コンテナ破損の可能性)" "remux"
  }

  if ($null -ne $firstPts -and $firstPts -lt 0) {
    $ptsSec = if ($tbVal) { "{0:0.###}s" -f ($firstPts * $tbVal) } else { "?" }
    if ($firstPts -lt -1000) {
      Add-Finding $r "WARN" "lada" "異常に大きい負の開始 PTS (first_pts=$firstPts, $ptsSec)。Intel QSV ではドライバクラッシュ回避のため VAAPI に強制される" "genpts"
    } else {
      Add-Finding $r "WARN" "lada" "負の開始 PTS (first_pts=$firstPts)。TorchCodec/NVDEC で同期破綻するため PyAV フォールバック (低速化)" "genpts"
    }
    Add-Finding $r "WARN" "jasna" "負の PTS のフレームは jasna ではデコード時に黙って捨てられる (先頭欠け・AV ずれの原因)" "genpts"
  }
  if ($null -ne $startTime -and $startTime -lt 0) {
    Add-Finding $r "WARN" "lada" ("負の start_time ({0:0.###}s)。TorchCodec→PyAV フォールバック (低速化)" -f $startTime) "genpts"
  }

  # --- standard: 全パケット PTS/DTS スキャン ---
  if ($Level -in @("standard", "full") -and -not $r.Failed) {
    Invoke-PacketScan $r $p $tbVal
  }

  # --- full: 全フレームデコード検証 ---
  if ($Level -eq "full" -and -not $r.Failed) {
    Invoke-DecodeCheck $r $p
  }

  return $r
}

# --- 全パケット PTS/DTS スキャン (standard / full) ---
function Invoke-PacketScan($Result, [string]$FilePath, $TimeBaseValue) {
  $ErrorActionPreference = "Continue"  # PS5.1: stderr リダイレクトでの NativeCommandError 停止を防ぐ
  $lines = & $FFprobe -v error -select_streams v:0 -show_entries packet=pts,dts -of csv=p=0 $FilePath 2>$null
  if ($LASTEXITCODE -ne 0 -or -not $lines) {
    Add-Finding $Result "WARN" "common" "パケットスキャンを実行できませんでした"
    return
  }

  $ptsList     = [System.Collections.Generic.List[long]]::new()
  $ptsSeen     = [System.Collections.Generic.HashSet[long]]::new()
  $missingPts  = 0
  $negativePts = 0
  $dupPts      = 0
  $dtsBackward = 0
  $prevDts     = [long]::MinValue

  foreach ($line in $lines) {
    if (-not $line) { continue }
    $parts = $line.Split(",")
    $ptsStr = $parts[0]
    $dtsStr = if ($parts.Count -gt 1) { $parts[1] } else { "N/A" }

    if ($ptsStr -eq "N/A" -or $ptsStr -eq "") {
      $missingPts++
    } else {
      $pts = [long]$ptsStr
      if ($pts -lt 0) { $negativePts++ }
      if (-not $ptsSeen.Add($pts)) { $dupPts++ }
      $ptsList.Add($pts)
    }
    if ($dtsStr -ne "N/A" -and $dtsStr -ne "") {
      $dts = [long]$dtsStr
      if ($dts -lt $prevDts) { $dtsBackward++ }
      $prevDts = $dts
    }
  }

  $total = $lines.Count
  if ($missingPts -gt 0) {
    Add-Finding $Result "FAIL" "common" "PTS の無いパケットが $missingPts / $total 個。フレームの時刻が決められず AV 同期が破綻する" "genpts"
  }
  if ($negativePts -gt 1) {
    Add-Finding $Result "WARN" "common" "負の PTS のパケットが $negativePts 個" "genpts"
  }
  if ($dupPts -gt 0) {
    Add-Finding $Result "FAIL" "common" "PTS が重複するパケットが $dupPts 個 (同時刻フレームの混在 = mux 不良)。少数ならそのまま処理が通ることも多いが、多いと再生のカクつきや AV 同期ずれの原因になる" "genpts"
  }
  if ($dtsBackward -gt 0) {
    Add-Finding $Result "FAIL" "common" "DTS が逆行する箇所が $dtsBackward 個 (デコード順の破綻。シーク/デコードが不安定になる)" "genpts"
  }

  # ソート後 PTS の異常ギャップ (VFR の大穴 = lada-ex の AV 同期ずれ原因)
  if ($ptsList.Count -ge 10 -and $TimeBaseValue) {
    $ptsList.Sort()
    $deltas = [long[]]::new($ptsList.Count - 1)
    for ($i = 1; $i -lt $ptsList.Count; $i++) { $deltas[$i - 1] = $ptsList[$i] - $ptsList[$i - 1] }
    $sortedDeltas = [long[]]$deltas.Clone()
    [Array]::Sort($sortedDeltas)
    $median = $sortedDeltas[[int]($sortedDeltas.Count / 2)]
    if ($median -gt 0) {
      $thresholdTicks = [math]::Max(4 * $median, [long](0.5 / $TimeBaseValue))
      $gapCount = 0; [long]$maxGap = 0
      foreach ($d in $deltas) {
        if ($d -gt $thresholdTicks) {
          $gapCount++
          if ($d -gt $maxGap) { $maxGap = $d }
        }
      }
      if ($gapCount -gt 0) {
        Add-Finding $Result "WARN" "lada" ("PTS に大きなギャップが {0} 箇所 (最大 {1:0.##}s)。lada-ex で AV 同期ずれの原因になるパターン" -f $gapCount, ($maxGap * $TimeBaseValue)) "vfr"
      }
    }
  }
}

# --- 全フレームデコード検証 (full) ---
function Invoke-DecodeCheck($Result, [string]$FilePath) {
  $ErrorActionPreference = "Continue"  # PS5.1: stderr リダイレクトでの NativeCommandError 停止を防ぐ
  # ffmpeg のエラーメッセージにはファイル名 (日本語) が含まれ得るため UTF-8 で復号する
  $prevEnc = [Console]::OutputEncoding
  try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $merged = & $FFmpeg -nostdin -v error -i $FilePath -map 0:v:0 -f null - 2>&1
  } finally { [Console]::OutputEncoding = $prevEnc }
  $errors = [System.Collections.Generic.List[string]]::new()
  foreach ($item in $merged) {
    if ($item -is [System.Management.Automation.ErrorRecord] -and $item.Exception.Message.Trim()) {
      $errors.Add($item.Exception.Message)
    }
  }
  if ($errors.Count -gt 0) {
    $sample = ($errors | Select-Object -First 3) -join " / "
    Add-Finding $Result "FAIL" "common" "デコードエラー $($errors.Count) 件 (ビットストリーム破損): $sample" "reencode_broken"
  }
}

# =====================================================================
# 修復コマンドの提示
# =====================================================================
function Get-FixSuggestion([string]$FixKey, $Result) {
  $p = $Result.File.FullName
  $stem = Join-Path $Result.File.DirectoryName $Result.File.BaseName
  switch ($FixKey) {
    "genpts" { @"
[PTS 異常] PTS を再生成して mkv に remux (無劣化・高速):
  ffmpeg -fflags +genpts -i "$p" -map 0 -c copy -avoid_negative_ts make_zero "${stem}_fixed.mkv"
"@ }
    "remux" { @"
[コンテナ問題] mkv に remux (無劣化・高速)。コンテナ破損ならこれで直ることが多い:
  ffmpeg -i "$p" -map 0 -c copy "${stem}_remux.mkv"
  ※ ffprobe 自体が失敗する場合は -err_detect ignore_err を -i の前に追加
"@ }
    "jasna_reencode" {
      $deint = if ($Result.Findings | Where-Object { $_.FixKey -eq "interlace" }) { ' -vf bwdif' } else { '' }
      @"
[jasna 非対応コーデック] HEVC (NVENC) に再エンコード:
  ffmpeg -i "$p" -map 0$deint -c:v hevc_nvenc -preset p5 -cq 19 -c:a copy "${stem}_hevc.mkv"
  ※ DVD ソース (mpeg2) でインターレースの場合は -vf bwdif を必ず付ける
"@ }
    "color_convert" { @"
[色空間非対応] BT.2020/HDR 等は BT.709 へ変換が必要 (再エンコード):
  ffmpeg -i "$p" -vf "zscale=t=linear:npl=100,tonemap=hable,zscale=t=bt709:m=bt709:r=tv,format=yuv420p" -c:v hevc_nvenc -preset p5 -cq 19 -c:a copy "${stem}_bt709.mkv"
  ※ HDR でない SDR 素材 (例: smpte240m) なら zscale 部分を -vf "colorspace=bt709,format=yuv420p" に置換
"@ }
    "color_tag" {
      if ($Result.Codec -in @("h264", "hevc")) {
        $bsf = "$($Result.Codec)_metadata"
        @"
[色空間タグ欠落] 実際の色が BT.709 なら、メタデータを書き込むだけで直る (無劣化):
  ffmpeg -i "$p" -map 0 -c copy -bsf:v:0 ${bsf}=colour_primaries=1:transfer_characteristics=1:matrix_coefficients=1 "${stem}_tagged.mkv"
  ※ SD (DVD) 素材で実際の色が BT.601 なら colour_primaries=5:transfer_characteristics=6:matrix_coefficients=5
"@
      } else {
        @"
[色空間タグ欠落] $($Result.Codec) はビットストリームへのタグ書き込み不可。
  jasna の自動推定 (HD→BT.709 / SD→BT.601) で色が正しければ対処不要。
  色がずれる場合のみ再エンコードでタグ付け:
  ffmpeg -i "$p" -map 0 -c:v hevc_nvenc -preset p5 -cq 19 -colorspace bt709 -color_primaries bt709 -color_trc bt709 -c:a copy "${stem}_tagged.mkv"
"@
      }
    }
    "range_tag" {
      if ($Result.Codec -in @("h264", "hevc")) {
        $bsf = "$($Result.Codec)_metadata"
        @"
[色レンジ不明] 通常の動画は limited (TV) レンジ。タグを付けて remux (無劣化):
  ffmpeg -i "$p" -map 0 -c copy -bsf:v:0 ${bsf}=video_full_range_flag=0 "${stem}_range.mkv"
"@
      } else {
        @"
[色レンジ不明] $($Result.Codec) は無劣化でのレンジタグ書き込み不可。
  lada-ex は PyAV フォールバックで処理自体は可能 (低速化のみ)。気になる場合は再エンコード:
  ffmpeg -i "$p" -map 0 -c:v hevc_nvenc -preset p5 -cq 19 -color_range tv -c:a copy "${stem}_range.mkv"
"@
      }
    }
    "vfr" { @"
[VFR / PTS ギャップ] remux では直らない。確実に直すには CFR 化の再エンコード:
  ffmpeg -i "$p" -fps_mode cfr -c:v hevc_nvenc -preset p5 -cq 19 -c:a copy "${stem}_cfr.mkv"
  ※ 画質劣化を伴うので、まず無加工のまま処理して AV ずれが出た場合のみ実施を推奨
"@ }
    "interlace" { @"
[インターレース] デインターレースして再エンコード:
  ffmpeg -i "$p" -vf bwdif -c:v hevc_nvenc -preset p5 -cq 19 -c:a copy "${stem}_deint.mkv"
"@ }
    "reencode_broken" { @"
[ビットストリーム破損] 壊れた部分を読み飛ばしつつ再エンコードで作り直す:
  ffmpeg -err_detect ignore_err -i "$p" -map 0 -c:v hevc_nvenc -preset p5 -cq 19 -c:a aac "${stem}_repaired.mkv"
  ※ 破損箇所のフレームは欠落/乱れる。元データの再入手が可能ならそちらを推奨
"@ }
    default { $null }
  }
}

# =====================================================================
# レポート出力
# =====================================================================
function Get-Verdict($Result, [string]$ToolScope) {
  $relevant = $Result.Findings | Where-Object { $_.Scope -in @("common", $ToolScope) }
  if ($relevant | Where-Object { $_.Severity -eq "FAIL" }) { return "NG" }
  if ($relevant | Where-Object { $_.Severity -eq "WARN" }) { return "注意" }
  return "OK"
}

function Get-VerdictColor([string]$Verdict) {
  switch ($Verdict) { "NG" { "Red" } "注意" { "Yellow" } default { "Green" } }
}

# 対象ツール ($Target) に関係する findings の FixKey を重複排除して返す。
# コンソール表示 (Write-FileReport) と修復スクリプト出力 (Write-FixScriptFile) で
# 同じ対象を提示するため、両者でこの関数を共用する。
function Get-RelevantFixKeys($Result) {
  $Result.Findings |
    Where-Object { $_.FixKey -and ($_.Scope -eq "common" -or
                   ($_.Scope -eq "lada" -and $Target -in @("lada", "both")) -or
                   ($_.Scope -eq "jasna" -and $Target -in @("jasna", "both"))) } |
    Select-Object -ExpandProperty FixKey -Unique
}

function Write-FileReport($Result) {
  Write-Host ""
  Write-Host "=== $($Result.File.Name) ===" -ForegroundColor Cyan
  if ($Result.MetaLine) {
    Write-Host "  メタデータ: $($Result.MetaLine)"
  }

  if ($Result.Findings.Count -eq 0) {
    Write-Host "  [OK]   問題は見つかりませんでした" -ForegroundColor Green
  } else {
    foreach ($f in $Result.Findings) {
      $tag = if ($f.Severity -eq "FAIL") { "[FAIL]" } else { "[WARN]" }
      $color = if ($f.Severity -eq "FAIL") { "Red" } else { "Yellow" }
      $scopeLabel = switch ($f.Scope) { "lada" { "(lada-ex) " } "jasna" { "(jasna) " } default { "" } }
      Write-Host "  $tag $scopeLabel$($f.Message)" -ForegroundColor $color
    }
  }

  # 判定行
  $verdictParts = @()
  if ($Target -in @("lada", "both"))  { $verdictParts += "lada-ex → $(Get-Verdict $Result 'lada')" }
  if ($Target -in @("jasna", "both")) { $verdictParts += "jasna → $(Get-Verdict $Result 'jasna')" }
  Write-Host "  判定: $($verdictParts -join ' / ')" -ForegroundColor White

  # 対処コマンド (対象ツールに関係する findings の FixKey を重複排除して提示)
  $fixKeys = Get-RelevantFixKeys $Result
  if ($fixKeys) {
    Write-Host ""
    Write-Host "  --- 対処 ---" -ForegroundColor Magenta
    foreach ($key in $fixKeys) {
      $text = Get-FixSuggestion $key $Result
      if ($text) {
        foreach ($line in ($text -split "`n")) { Write-Host "  $line" }
      }
    }
  }
}

# =====================================================================
# 修復スクリプトの書き出し (-FixScript)
# =====================================================================
# コンソールに出る対処コマンドを、後で PowerShell から一括実行できる 1 つのファイルに集約する。
# ffmpeg の行はそのまま実行可能な行として、説明 (例: [PTS 異常] ...) や注記 (※ ...) は
# # コメントとして書き出す。出力先が .ps1 ならそのまま実行、コピペでの利用も可能。
# 日本語コメントを含むため、PS5.1 で実行/編集しても壊れないよう UTF-8 BOM 付きで保存する。
function Write-FixScriptFile($Results, [string]$OutPath) {
  $full = if ([System.IO.Path]::IsPathRooted($OutPath)) { $OutPath }
          else { Join-Path (Get-Location).Path $OutPath }

  $sb = [System.Collections.Generic.List[string]]::new()
  $sb.Add("# Check-VideoInput 対処コマンド集")
  $sb.Add("# 生成日時: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') / Target=$Target / Level=$Level")
  $sb.Add("# 各 ffmpeg 行はそのまま実行可能。# の行は説明/注記。不要な対処は削除してから実行すること")
  $sb.Add("# 同一ファイルに複数の対処がある場合、それぞれ別の出力ファイルを作る。必要なものだけ残すこと")
  $sb.Add("")

  $count = 0
  foreach ($res in $Results) {
    $fixKeys = Get-RelevantFixKeys $res
    if (-not $fixKeys) { continue }
    $count++
    $sb.Add("# ============================================================")
    $sb.Add("# $($res.File.Name)")
    if ($res.MetaLine) { $sb.Add("#   $($res.MetaLine)") }
    $sb.Add("# ============================================================")
    foreach ($key in $fixKeys) {
      $text = Get-FixSuggestion $key $res
      if (-not $text) { continue }
      foreach ($line in ($text -split "`n")) {
        $t = $line.Trim()
        if (-not $t) { continue }
        if ($t -like "ffmpeg *") { $sb.Add($t) }
        else { $sb.Add("# $t") }
      }
      $sb.Add("")
    }
  }

  if ($count -eq 0) {
    $sb.Add("# 対処が必要なファイルはありませんでした")
  }

  $content = ($sb -join "`r`n") + "`r`n"
  $enc = New-Object System.Text.UTF8Encoding($true)  # BOM 付き
  [System.IO.File]::WriteAllText($full, $content, $enc)
  Write-Host ""
  Write-Host "対処コマンドを出力しました: $full ($count ファイル分)" -ForegroundColor Green
}

# =====================================================================
# メイン
# =====================================================================
if (-not (Test-Path $Path)) {
  Write-Host "ERROR: パスが見つかりません: $Path" -ForegroundColor Red
  exit 2
}

$files = @()
$item = Get-Item $Path
if ($item.PSIsContainer) {
  $files = Get-ChildItem -Path $Path -File -Recurse:$Recurse |
    Where-Object { $_.Extension.ToLower() -in $ScanExtensions } |
    Sort-Object FullName
  if (-not $files) {
    Write-Host "ERROR: 対象の動画ファイルが見つかりません: $Path" -ForegroundColor Red
    exit 2
  }
} else {
  $files = @($item)
}

Write-Host "チェック対象: $($files.Count) ファイル / Target=$Target / Level=$Level" -ForegroundColor White

$results = @()
foreach ($f in $files) {
  $results += Test-VideoFile $f
  Write-FileReport $results[-1]
}

# --- サマリ (複数ファイル時のみ) ---
if ($results.Count -gt 1) {
  Write-Host ""
  Write-Host "=== サマリ ===" -ForegroundColor Cyan
  # Format-Table は使わない。長い日本語ファイル名がコンソール幅を使い切ると
  # AutoSize が判定列を黙って切り捨てるため。判定を先頭に置き 1 ファイル 1 行で出す
  foreach ($res in $results) {
    Write-Host "  " -NoNewline
    if ($Target -in @("lada", "both")) {
      $v = Get-Verdict $res "lada"
      Write-Host "lada-ex:" -NoNewline
      Write-Host $v.PadRight(4) -NoNewline -ForegroundColor (Get-VerdictColor $v)
    }
    if ($Target -in @("jasna", "both")) {
      $v = Get-Verdict $res "jasna"
      Write-Host "jasna:" -NoNewline
      Write-Host $v.PadRight(4) -NoNewline -ForegroundColor (Get-VerdictColor $v)
    }
    Write-Host " $($res.File.Name)"
    $first = $res.Findings | Where-Object Severity -eq "FAIL" | Select-Object -First 1
    if (-not $first) { $first = $res.Findings | Select-Object -First 1 }
    if ($first) { Write-Host "      $($first.Message)" -ForegroundColor DarkGray }
  }
}

# --- 修復スクリプトの書き出し ---
if ($FixScript) {
  Write-FixScriptFile $results $FixScript
}

# --- 終了コード: 対象ツールに関係する findings だけで決める ---
$relevantScopes = @("common")
if ($Target -in @("lada", "both"))  { $relevantScopes += "lada" }
if ($Target -in @("jasna", "both")) { $relevantScopes += "jasna" }
$allRelevant = $results.Findings | Where-Object { $_.Scope -in $relevantScopes }

if ($allRelevant | Where-Object { $_.Severity -eq "FAIL" }) { exit 2 }
if ($allRelevant | Where-Object { $_.Severity -eq "WARN" }) { exit 1 }
exit 0
