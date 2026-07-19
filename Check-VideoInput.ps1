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
#   .\Check-VideoInput.ps1 D:\videos -Lang en        (英語で表示。既定は OS のカルチャで自動判別)
#   Check-VideoInput.bat <ファイル|フォルダ>   (cmd から。pwsh → powershell.exe の順で自動選択)
#
# チェックレベル:
#   quick    : ffprobe メタデータ + 先頭パケットのみ (数秒)
#   standard : quick + 全パケット PTS/DTS スキャン (既定。数GB で数十秒)
#   full     : standard + 全フレームデコード検証 (最も確実。実時間の数分の一)
#
# 表示言語 (-Lang):
#   auto (既定) : OS のカルチャが ja なら日本語、それ以外は英語
#   ja          : 日本語
#   en          : 英語
#
# 終了コード: 0=全て OK / 1=WARN あり / 2=FAIL あり
#
# 判定根拠 (各ツール main ブランチのソース調査による):
#   lada-ex : lada/utils/video_utils.py — 拡張子ホワイトリスト、first_pts<0 や
#             time_base=1/10000000 で TorchCodec→PyAV フォールバック (低速化)、
#             first_pts<-1000 で QSV クラッシュ回避、VFR 大ギャップで AV 同期ずれ
#   jasna   : 0.8.1 でメディア層が python_vali/PyNvVideoCodec から PyAV に全面移行し、
#             入力制約が大きく変わったため -JasnaVersion で判定基準を切り替える。
#     0.7.2 : NVDEC 必須でフォールバックが無く、h264/hevc/vp9/av1 以外は処理不能。
#             負の PTS のフレームはデコード時に黙って捨てられる
#     0.8.1 : CPU デコードへ自動フォールバックするためコーデック制限は「非対応」ではなく
#             「低速化」。BT.2020 に対応。負 PTS は破棄せず原点を 0 に平行移動する。
#             一方で奇数解像度 (rgb_to_nv12.py の ValueError) が新たな致命傷になった
#     共通    : 未知の color_space タグは黙って BT.709 に読み替えられる (例外にはならず色がずれる)。
#             duration がストリームにもコンテナにも無いとメタデータ読み取りで KeyError

[CmdletBinding(DefaultParameterSetName="Check")]
param(
  [Parameter(ParameterSetName="Check", Mandatory=$true, Position=0)]
  [string]$Path,

  [ValidateSet("lada", "jasna", "both")]
  [string]$Target = "both",

  [ValidateSet("quick", "standard", "full")]
  [string]$Level = "standard",

  # 判定基準とする jasna のバージョン。0.8.1 でメディア層が PyAV に移行し制約が大きく変わった。
  # -Target が jasna / both のときのみ意味を持つ
  [ValidateSet("0.7.2", "0.8.1")]
  [string]$JasnaVersion = "0.8.1",

  # jasna の --segments (スマートレンダリング) 使用を前提に厳格な追加チェックを行う (0.8.1 のみ)
  [switch]$Segments,

  # 表示言語。auto は OS のカルチャで日本語/英語を判別する
  [ValidateSet("ja", "en", "auto")]
  [string]$Lang = "auto",

  [switch]$Recurse,

  [string]$FFprobePath,
  [string]$FFmpegPath,

  [string]$FixScript,

  # バージョンを表示して終了する (検査は行わない)
  [Parameter(ParameterSetName="Version", Mandatory=$true)]
  [switch]$Version
)

$ErrorActionPreference = "Stop"

# ツールのバージョン。リリースごとに更新する (README.md / README.en.md のバージョン行も同時に更新すること)
$ToolVersion = "1.2.0"

# -Version: ffprobe/ffmpeg の検出より前に処理する (ツール未導入でも表示できるように)
if ($Version) {
  Write-Host "Check-VideoInput $ToolVersion"
  exit 0
}

# --- 表示言語の確定 ---
# auto のときは OS のカルチャを見て日本語/英語を選ぶ。明示指定 (ja/en) はそのまま使う。
if ($Lang -eq "auto") {
  $Lang = if ((Get-Culture).TwoLetterISOLanguageName -eq "ja") { "ja" } else { "en" }
}

# --- メッセージカタログ ---
# 表示文字列はすべてここに集約し、キー引き (T 関数) で取得する。補間が要るものは
# String.Format の書式文字列として持ち、呼び出し側で -f で値を埋める。
# 修復コマンドの here-string にはリテラルの { } が無いため -f 化は安全。
$Strings = @{
  ja = @{
    # --- 検出メッセージ ---
    file_zero              = 'ファイルサイズが 0 バイト'
    ffprobe_fail           = 'ffprobe がファイルを解析できません (コンテナ破損の可能性): {0}'
    no_video_stream        = '映像ストリームがありません'
    audio_none             = 'なし'
    fps_unknown            = 'fps不明'
    meta_audio_label       = '音声'
    fps_fail               = 'フレームレートが取得できません (r_frame_rate={0})'
    duration_fail          = 'duration が取得できません (コンテナのインデックス欠落の可能性)'
    resolution_fail        = '解像度が取得できません'
    vfr_detect             = 'VFR (可変フレームレート) の可能性: r_frame_rate={0:0.###} と avg_frame_rate={1:0.###} が不一致'
    interlace_detect       = 'インターレース素材 (field_order={0})。検出/復元精度が落ちるためデインターレース推奨'
    colorspace_unset       = 'color_space 未設定。jasna は未設定タグを黙って BT.709 として扱うため、実際が BT.601/BT.2020 だと色がずれる'
    colorspace_unsupported = 'color_space={0} は jasna が認識しないタグ。黙って BT.709 に読み替えられるため、実際の色との差がそのまま出力に残る (認識されるのは {1})'
    colorrange_unknown     = 'color_range 不明。lada-ex は推定不能時 TorchCodec→PyAV フォールバック (低速化)'
    ext_unsupported        = '拡張子 {0} は lada-ex の対応リスト外'
    codec_unsupported      = 'コーデック {0} は jasna (NVDEC) 非対応 — 対応は {1} のみ'
    codec_slow             = 'コーデック {0} は jasna のハードウェアデコード対象外 (対象は {1})。CPU デコードへ黙ってフォールバックするため大幅に低速化する'
    jasna_odd_dims         = '幅または高さが奇数 ({0}x{1})。jasna は NV12 変換で偶数の解像度を要求するため、エンコード開始後に ValueError で停止する'
    jasna_duration_missing = 'duration がストリームにもコンテナにもありません。jasna はメタデータ読み取り時に KeyError で停止します'
    jasna_start_pts_missing = 'start_pts がありません。jasna の GUI プレビューが TypeError で停止します (CLI での実行は可能)'
    jasna_hdr              = 'HDR 素材 (color_trc={0})。jasna はトーンマップを一切行わず転送特性をそのまま通すため、白飛び/暗転した出力になります'
    jasna_interlace        = 'インターレース素材 (field_order={0})。jasna はデインターレースを行わないため、櫛状ノイズが出力に残り検出精度も落ちます'
    jasna_chroma           = 'クロマサブサンプリングが 4:2:0 以外 (pix_fmt={0})。jasna は 4:2:0 に間引いて処理するため色解像度が失われます'
    jasna_bitdepth_reduced = '{0}bit 素材 (pix_fmt={1})。jasna は {2}bit に落として処理します'
    jasna_extra_streams    = '{0}は jasna の出力に引き継がれず黙って失われます (映像 1 本 + 音声のみが muxing 対象)'
    jasna_stream_subtitle  = '字幕 {0} 本'
    jasna_stream_data      = 'データ {0} 本'
    jasna_stream_attachment = '添付 {0} 本'
    jasna_stream_chapter   = 'チャプター {0} 個'
    jasna_multi_video      = '映像ストリームが {0} 本あります。jasna は先頭の 1 本のみを処理し、残りは出力に含まれません'
    jasna_ext_folder       = '拡張子 {0} は jasna のフォルダ走査対象 ({1}) 外です。ファイルを個別に指定すれば処理できます'
    jasna_audio_no_ts      = 'PTS と DTS の両方が無い音声パケットが {0} 個。jasna はこれらを破棄するため音が欠けます'
    seg_codec              = '--segments (スマートレンダリング) はコーデック {0} に非対応 — 対応は {1}'
    seg_pixfmt             = '--segments は pix_fmt {0} に非対応 — 対応は {1}'
    seg_field_order        = '--segments はプログレッシブ素材のみ対応 (field_order={0})'
    seg_h264_10bit         = '10bit の H.264 は --segments 非対応'
    seg_h264_profile       = 'H.264 の profile {0} は --segments 非対応 — 対応は {1}'
    seg_vfr                = '--segments は CFR 必須。r_frame_rate と avg_frame_rate が {0:0.###}% ずれています (許容 0.1%)'
    seg_ext                = '--segments の出力コンテナは {0} のみ。入力の拡張子は {1} なので、出力の拡張子を明示的に指定してください'
    timebase_incompatible  = 'time_base=1/10000000 は TorchCodec exact seek 非互換 → PyAV フォールバック (低速化)'
    first_pkt_no_pts       = '先頭パケットの PTS がありません (壊れた AVI などのパターン。フレームのタイムスタンプが信頼できない)'
    first_pkt_unreadable   = '先頭パケットを読み取れません (コンテナ破損の可能性)'
    neg_pts_large          = '異常に大きい負の開始 PTS (first_pts={0}, {1})。Intel QSV ではドライバクラッシュ回避のため VAAPI に強制される'
    neg_pts                = '負の開始 PTS (first_pts={0})。TorchCodec/NVDEC で同期破綻するため PyAV フォールバック (低速化)'
    neg_pts_jasna          = '負の PTS のフレームは jasna ではデコード時に黙って捨てられる (先頭欠け・AV ずれの原因)'
    neg_pts_jasna_kept     = 'jasna は負の PTS のフレームを破棄せず、先頭を 0 に平行移動する。ただし重複/非単調な PTS は +1 されるため微小な時刻ずれが残る'
    neg_start_time         = '負の start_time ({0:0.###}s)。TorchCodec→PyAV フォールバック (低速化)'
    pktscan_fail           = 'パケットスキャンを実行できませんでした'
    pktscan_missing_pts    = 'PTS の無いパケットが {0} / {1} 個。フレームの時刻が決められず AV 同期が破綻する'
    pktscan_neg_pts        = '負の PTS のパケットが {0} 個'
    pktscan_dup_pts        = 'PTS が重複するパケットが {0} 個 (同時刻フレームの混在 = mux 不良)。少数ならそのまま処理が通ることも多いが、多いと再生のカクつきや AV 同期ずれの原因になる'
    pktscan_dts_backward   = 'DTS が逆行する箇所が {0} 個 (デコード順の破綻。シーク/デコードが不安定になる)'
    pktscan_gap            = 'PTS に大きなギャップが {0} 箇所 (最大 {1:0.##}s)。lada-ex で AV 同期ずれの原因になるパターン'
    decode_error           = 'デコードエラー {0} 件 (ビットストリーム破損): {1}'

    # --- 修復コマンド ---
    fix_genpts = @'
[PTS 異常] PTS を再生成して mkv に remux (無劣化・高速):
  ffmpeg -fflags +genpts -i "{0}" -map 0 -map -0:d -c copy -avoid_negative_ts make_zero "{1}_fixed.mkv"
'@
    fix_remux = @'
[コンテナ問題] mkv に remux (無劣化・高速)。コンテナ破損ならこれで直ることが多い:
  ffmpeg -i "{0}" -map 0 -map -0:d -c copy "{1}_remux.mkv"
  ※ ffprobe 自体が失敗する場合は -err_detect ignore_err を -i の前に追加
'@
    fix_jasna_reencode = @'
[jasna 非対応コーデック] HEVC (NVENC) に再エンコード:
  ffmpeg -i "{0}" -map 0 -map -0:d{2} -c:v hevc_nvenc -preset p5 -cq 19 -c:a copy "{1}_hevc.mkv"
  ※ DVD ソース (mpeg2) でインターレースの場合は -vf bwdif を必ず付ける
'@
    fix_jasna_reencode_speed = @'
[jasna のハードウェアデコード対象外] 処理自体は通るため対処は任意。速度を優先するなら HEVC (NVENC) に再エンコード:
  ffmpeg -i "{0}" -map 0 -map -0:d{2} -c:v hevc_nvenc -preset p5 -cq 19 -c:a copy "{1}_hevc.mkv"
  ※ 再エンコードは画質劣化を伴う。1 回しか処理しないなら低速のまま通す方が有利なことも多い
'@
    fix_color_convert = @'
[HDR 素材] トーンマップして BT.709 (SDR) へ変換 (再エンコード):
  ffmpeg -i "{0}" -vf "zscale=t=linear:npl=100,tonemap=hable,zscale=t=bt709:m=bt709:r=tv,format=yuv420p" -c:v hevc_nvenc -preset p5 -cq 19 -c:a copy "{1}_bt709.mkv"
  ※ HDR でない SDR 素材 (例: smpte240m) なら zscale 部分を -vf "colorspace=bt709,format=yuv420p" に置換
'@
    fix_color_tag_meta = @'
[色空間タグ欠落] 実際の色が BT.709 なら、メタデータを書き込むだけで直る (無劣化):
  ffmpeg -i "{0}" -map 0 -map -0:d -c copy -bsf:v:0 {2}=colour_primaries=1:transfer_characteristics=1:matrix_coefficients=1 "{1}_tagged.mkv"
  ※ SD (DVD) 素材で実際の色が BT.601 なら colour_primaries=5:transfer_characteristics=6:matrix_coefficients=5
'@
    fix_color_tag_reencode = @'
[色空間タグ欠落] {2} はビットストリームへのタグ書き込み不可。
  jasna の自動推定 (HD→BT.709 / SD→BT.601) で色が正しければ対処不要。
  色がずれる場合のみ再エンコードでタグ付け:
  ffmpeg -i "{0}" -map 0 -map -0:d -c:v hevc_nvenc -preset p5 -cq 19 -colorspace bt709 -color_primaries bt709 -color_trc bt709 -c:a copy "{1}_tagged.mkv"
'@
    fix_range_tag_meta = @'
[色レンジ不明] 通常の動画は limited (TV) レンジ。タグを付けて remux (無劣化):
  ffmpeg -i "{0}" -map 0 -map -0:d -c copy -bsf:v:0 {2}=video_full_range_flag=0 "{1}_range.mkv"
'@
    fix_range_tag_reencode = @'
[色レンジ不明] {2} は無劣化でのレンジタグ書き込み不可。
  lada-ex は PyAV フォールバックで処理自体は可能 (低速化のみ)。気になる場合は再エンコード:
  ffmpeg -i "{0}" -map 0 -map -0:d -c:v hevc_nvenc -preset p5 -cq 19 -color_range tv -c:a copy "{1}_range.mkv"
'@
    fix_vfr = @'
[VFR / PTS ギャップ] remux では直らない。確実に直すには CFR 化の再エンコード:
  ffmpeg -i "{0}" -fps_mode cfr -c:v hevc_nvenc -preset p5 -cq 19 -c:a copy "{1}_cfr.mkv"
  ※ 画質劣化を伴うので、まず無加工のまま処理して AV ずれが出た場合のみ実施を推奨
'@
    fix_interlace = @'
[インターレース] デインターレースして再エンコード:
  ffmpeg -i "{0}" -vf bwdif -c:v hevc_nvenc -preset p5 -cq 19 -c:a copy "{1}_deint.mkv"
'@
    fix_reencode_broken = @'
[ビットストリーム破損] 壊れた部分を読み飛ばしつつ再エンコードで作り直す:
  ffmpeg -err_detect ignore_err -i "{0}" -map 0 -map -0:d -c:v hevc_nvenc -preset p5 -cq 19 -c:a aac "{1}_repaired.mkv"
  ※ 破損箇所のフレームは欠落/乱れる。元データの再入手が可能ならそちらを推奨
'@
    fix_even_dims = @'
[奇数解像度] 偶数に切り詰めて再エンコード:
  ffmpeg -i "{0}" -vf "crop=trunc(iw/2)*2:trunc(ih/2)*2" -c:v hevc_nvenc -preset p5 -cq 19 -c:a copy "{1}_even.mkv"
  ※ 端が 1px 削られる。削りたくない場合は -vf "pad=ceil(iw/2)*2:ceil(ih/2)*2" でパディングする
'@
    fix_pixfmt_420 = @'
[クロマ / ビット深度] 8bit 4:2:0 に変換して再エンコード:
  ffmpeg -i "{0}" -vf format=yuv420p -c:v hevc_nvenc -preset p5 -cq 19 -c:a copy "{1}_420.mkv"
'@

    # --- 判定ラベル ---
    verdict_ok   = 'OK'
    verdict_warn = '注意'
    verdict_fail = 'NG'

    # --- 表示ラベル ---
    label_metadata = 'メタデータ'
    no_problems    = '問題は見つかりませんでした'
    label_verdict  = '判定'
    label_fixes    = '--- 対処 ---'
    summary_header = '=== サマリ ==='
    scan_target    = 'チェック対象: {0} ファイル / Target={1} / Level={2}'
    scope_lada     = '(lada-ex) '
    scope_jasna    = '(jasna {0}) '
    label_lada     = 'lada-ex'
    label_jasna    = 'jasna {0}'
    scan_jasna_spec = 'jasna 仕様バージョン: {0}{1}'
    segments_suffix = ' (--segments チェック有効)'

    # --- エラー ---
    err_path_notfound = 'ERROR: パスが見つかりません: {0}'
    err_no_video      = 'ERROR: 対象の動画ファイルが見つかりません: {0}'
    err_tool_override = 'ERROR: 指定された {0} が見つかりません: {1}'
    err_tool_notfound = 'ERROR: {0} が見つかりません。PATH に追加するか、環境変数 FFMPEG_BIN_DIR で ffmpeg/ffprobe の置き場所を指定するか、-{0}Path で明示してください'

    # --- 修復スクリプト書き出し ---
    fixscript_h1      = '# Check-VideoInput 対処コマンド集'
    fixscript_h2      = '# 生成日時: {0} / Target={1} / Level={2}'
    fixscript_h2b     = '# jasna 仕様バージョン: {0}{1}'
    fixscript_h3      = '# 各 ffmpeg 行はそのまま実行可能。# の行は説明/注記。不要な対処は削除してから実行すること'
    fixscript_h4      = '# 同一ファイルに複数の対処がある場合、それぞれ別の出力ファイルを作る。必要なものだけ残すこと'
    fixscript_none    = '# 対処が必要なファイルはありませんでした'
    fixscript_written = '対処コマンドを出力しました: {0} ({1} ファイル分)'
  }
  en = @{
    # --- detection messages ---
    file_zero              = 'File size is 0 bytes'
    ffprobe_fail           = 'ffprobe cannot parse the file (possible container corruption): {0}'
    no_video_stream        = 'No video stream'
    audio_none             = 'none'
    fps_unknown            = 'fps unknown'
    meta_audio_label       = 'audio'
    fps_fail               = 'Cannot determine frame rate (r_frame_rate={0})'
    duration_fail          = 'Cannot determine duration (container index may be missing)'
    resolution_fail        = 'Cannot determine resolution'
    vfr_detect             = 'Possible VFR (variable frame rate): r_frame_rate={0:0.###} and avg_frame_rate={1:0.###} differ'
    interlace_detect       = 'Interlaced source (field_order={0}). Deinterlacing recommended; detection/restoration accuracy drops otherwise'
    colorspace_unset       = 'color_space not set. jasna silently treats unset tags as BT.709, so colors shift if the source is actually BT.601/BT.2020'
    colorspace_unsupported = 'color_space={0} is a tag jasna does not recognize. It is silently coerced to BT.709, so any mismatch with the real colors carries into the output (recognized: {1})'
    colorrange_unknown     = 'color_range unknown. lada-ex falls back from TorchCodec to PyAV when it cannot infer (slower)'
    ext_unsupported        = 'Extension {0} is not in lada-ex''s supported list'
    codec_unsupported      = 'Codec {0} is not supported by jasna (NVDEC) — only {1} are supported'
    codec_slow             = 'Codec {0} is outside jasna''s hardware-decode set ({1}). It silently falls back to CPU decoding, which is much slower'
    jasna_odd_dims         = 'Odd width or height ({0}x{1}). jasna requires even dimensions for NV12 conversion and aborts with a ValueError after encoding has started'
    jasna_duration_missing = 'duration is missing from both the stream and the container. jasna aborts with a KeyError while reading metadata'
    jasna_start_pts_missing = 'start_pts is missing. jasna''s GUI preview aborts with a TypeError (CLI runs still work)'
    jasna_hdr              = 'HDR source (color_trc={0}). jasna performs no tone mapping and passes the transfer characteristics through, so the output looks blown out or crushed'
    jasna_interlace        = 'Interlaced source (field_order={0}). jasna does not deinterlace, so combing remains in the output and detection accuracy drops'
    jasna_chroma           = 'Chroma subsampling is not 4:2:0 (pix_fmt={0}). jasna subsamples to 4:2:0, losing color resolution'
    jasna_bitdepth_reduced = '{0}-bit source (pix_fmt={1}). jasna reduces it to {2}-bit'
    jasna_extra_streams    = '{0} will be silently lost — jasna muxes only the first video stream plus the audio streams'
    jasna_stream_subtitle  = '{0} subtitle stream(s)'
    jasna_stream_data      = '{0} data stream(s)'
    jasna_stream_attachment = '{0} attachment stream(s)'
    jasna_stream_chapter   = '{0} chapter(s)'
    jasna_multi_video      = '{0} video streams found. jasna processes only the first one; the rest are absent from the output'
    jasna_ext_folder       = 'Extension {0} is outside jasna''s folder-scan list ({1}). Passing the file individually still works'
    jasna_audio_no_ts      = '{0} audio packets have neither PTS nor DTS. jasna drops them, causing audio dropouts'
    seg_codec              = '--segments (smart rendering) does not support codec {0} — supported: {1}'
    seg_pixfmt             = '--segments does not support pix_fmt {0} — supported: {1}'
    seg_field_order        = '--segments supports progressive sources only (field_order={0})'
    seg_h264_10bit         = '10-bit H.264 is not supported by --segments'
    seg_h264_profile       = 'H.264 profile {0} is not supported by --segments — supported: {1}'
    seg_vfr                = '--segments requires CFR. r_frame_rate and avg_frame_rate differ by {0:0.###}% (tolerance 0.1%)'
    seg_ext                = '--segments only writes {0} containers. The input extension is {1}, so specify the output extension explicitly'
    timebase_incompatible  = 'time_base=1/10000000 is incompatible with TorchCodec exact seek → PyAV fallback (slower)'
    first_pkt_no_pts       = 'First packet has no PTS (a pattern seen in broken AVIs; frame timestamps cannot be trusted)'
    first_pkt_unreadable   = 'Cannot read the first packet (possible container corruption)'
    neg_pts_large          = 'Abnormally large negative start PTS (first_pts={0}, {1}). On Intel QSV this forces VAAPI to avoid a driver crash'
    neg_pts                = 'Negative start PTS (first_pts={0}). Sync breaks on TorchCodec/NVDEC, so it falls back to PyAV (slower)'
    neg_pts_jasna          = 'Frames with negative PTS are silently dropped by jasna during decoding (causes missing head / AV desync)'
    neg_pts_jasna_kept     = 'jasna does not drop negative-PTS frames; it shifts the origin to 0. Duplicate/non-monotonic PTS values are bumped by +1, leaving small timing shifts'
    neg_start_time         = 'Negative start_time ({0:0.###}s). TorchCodec→PyAV fallback (slower)'
    pktscan_fail           = 'Could not run the packet scan'
    pktscan_missing_pts    = '{0} of {1} packets have no PTS. Frame times cannot be determined and AV sync breaks'
    pktscan_neg_pts        = '{0} packets have a negative PTS'
    pktscan_dup_pts        = '{0} packets have duplicate PTS (same-time frames mixed in = bad mux). A few often pass fine, but many cause playback stutter and AV desync'
    pktscan_dts_backward   = '{0} places where DTS goes backward (broken decode order; seeking/decoding becomes unstable)'
    pktscan_gap            = '{0} large PTS gaps (max {1:0.##}s). A pattern that causes AV desync in lada-ex'
    decode_error           = '{0} decode errors (bitstream corruption): {1}'

    # --- fix commands ---
    fix_genpts = @'
[PTS problem] Regenerate PTS and remux to mkv (lossless, fast):
  ffmpeg -fflags +genpts -i "{0}" -map 0 -map -0:d -c copy -avoid_negative_ts make_zero "{1}_fixed.mkv"
'@
    fix_remux = @'
[Container problem] Remux to mkv (lossless, fast). Often fixes container corruption:
  ffmpeg -i "{0}" -map 0 -map -0:d -c copy "{1}_remux.mkv"
  Note: if ffprobe itself fails, add -err_detect ignore_err before -i
'@
    fix_jasna_reencode = @'
[jasna-unsupported codec] Re-encode to HEVC (NVENC):
  ffmpeg -i "{0}" -map 0 -map -0:d{2} -c:v hevc_nvenc -preset p5 -cq 19 -c:a copy "{1}_hevc.mkv"
  Note: for interlaced DVD sources (mpeg2), always add -vf bwdif
'@
    fix_jasna_reencode_speed = @'
[Outside jasna's hardware-decode set] Processing still works, so this is optional. For speed, re-encode to HEVC (NVENC):
  ffmpeg -i "{0}" -map 0 -map -0:d{2} -c:v hevc_nvenc -preset p5 -cq 19 -c:a copy "{1}_hevc.mkv"
  Note: re-encoding degrades quality. If you only process the file once, taking the slow path is often the better trade
'@
    fix_color_convert = @'
[HDR source] Tone-map and convert to BT.709 (SDR) (re-encode):
  ffmpeg -i "{0}" -vf "zscale=t=linear:npl=100,tonemap=hable,zscale=t=bt709:m=bt709:r=tv,format=yuv420p" -c:v hevc_nvenc -preset p5 -cq 19 -c:a copy "{1}_bt709.mkv"
  Note: for non-HDR SDR sources (e.g. smpte240m), replace the zscale part with -vf "colorspace=bt709,format=yuv420p"
'@
    fix_color_tag_meta = @'
[Missing color space tag] If the actual colors are BT.709, just writing the metadata fixes it (lossless):
  ffmpeg -i "{0}" -map 0 -map -0:d -c copy -bsf:v:0 {2}=colour_primaries=1:transfer_characteristics=1:matrix_coefficients=1 "{1}_tagged.mkv"
  Note: for SD (DVD) sources whose actual colors are BT.601, use colour_primaries=5:transfer_characteristics=6:matrix_coefficients=5
'@
    fix_color_tag_reencode = @'
[Missing color space tag] {2} does not support writing tags into the bitstream.
  No action needed if jasna's auto guess (HD→BT.709 / SD→BT.601) gives correct colors.
  Only tag via re-encode if colors are off:
  ffmpeg -i "{0}" -map 0 -map -0:d -c:v hevc_nvenc -preset p5 -cq 19 -colorspace bt709 -color_primaries bt709 -color_trc bt709 -c:a copy "{1}_tagged.mkv"
'@
    fix_range_tag_meta = @'
[Unknown color range] Most videos use limited (TV) range. Add the tag and remux (lossless):
  ffmpeg -i "{0}" -map 0 -map -0:d -c copy -bsf:v:0 {2}=video_full_range_flag=0 "{1}_range.mkv"
'@
    fix_range_tag_reencode = @'
[Unknown color range] {2} does not support lossless range-tag writing.
  lada-ex can still process it via PyAV fallback (only slower). Re-encode if it bothers you:
  ffmpeg -i "{0}" -map 0 -map -0:d -c:v hevc_nvenc -preset p5 -cq 19 -color_range tv -c:a copy "{1}_range.mkv"
'@
    fix_vfr = @'
[VFR / PTS gap] Remux does not fix this. To fix reliably, re-encode to CFR:
  ffmpeg -i "{0}" -fps_mode cfr -c:v hevc_nvenc -preset p5 -cq 19 -c:a copy "{1}_cfr.mkv"
  Note: this degrades quality, so first try processing as-is and only do this if AV desync appears
'@
    fix_interlace = @'
[Interlaced] Deinterlace and re-encode:
  ffmpeg -i "{0}" -vf bwdif -c:v hevc_nvenc -preset p5 -cq 19 -c:a copy "{1}_deint.mkv"
'@
    fix_reencode_broken = @'
[Bitstream corruption] Skip the broken parts and rebuild by re-encoding:
  ffmpeg -err_detect ignore_err -i "{0}" -map 0 -map -0:d -c:v hevc_nvenc -preset p5 -cq 19 -c:a aac "{1}_repaired.mkv"
  Note: frames at corrupted spots will be missing/glitched. If you can re-obtain the source, prefer that
'@
    fix_even_dims = @'
[Odd dimensions] Crop to even dimensions and re-encode:
  ffmpeg -i "{0}" -vf "crop=trunc(iw/2)*2:trunc(ih/2)*2" -c:v hevc_nvenc -preset p5 -cq 19 -c:a copy "{1}_even.mkv"
  Note: this shaves 1px off an edge. To pad instead, use -vf "pad=ceil(iw/2)*2:ceil(ih/2)*2"
'@
    fix_pixfmt_420 = @'
[Chroma / bit depth] Convert to 8-bit 4:2:0 and re-encode:
  ffmpeg -i "{0}" -vf format=yuv420p -c:v hevc_nvenc -preset p5 -cq 19 -c:a copy "{1}_420.mkv"
'@

    # --- verdict labels ---
    verdict_ok   = 'OK'
    verdict_warn = 'WARN'
    verdict_fail = 'NG'

    # --- display labels ---
    label_metadata = 'Metadata'
    no_problems    = 'No problems found'
    label_verdict  = 'Verdict'
    label_fixes    = '--- Fixes ---'
    summary_header = '=== Summary ==='
    scan_target    = 'Checking {0} file(s) / Target={1} / Level={2}'
    scope_lada     = '(lada-ex) '
    scope_jasna    = '(jasna {0}) '
    label_lada     = 'lada-ex'
    label_jasna    = 'jasna {0}'
    scan_jasna_spec = 'jasna spec version: {0}{1}'
    segments_suffix = ' (--segments checks enabled)'

    # --- errors ---
    err_path_notfound = 'ERROR: Path not found: {0}'
    err_no_video      = 'ERROR: No target video files found: {0}'
    err_tool_override = 'ERROR: The specified {0} was not found: {1}'
    err_tool_notfound = 'ERROR: {0} not found. Add it to PATH, set the FFMPEG_BIN_DIR environment variable to the ffmpeg/ffprobe folder, or specify it with -{0}Path'

    # --- fix-script output ---
    fixscript_h1      = '# Check-VideoInput fix command collection'
    fixscript_h2      = '# Generated: {0} / Target={1} / Level={2}'
    fixscript_h2b     = '# jasna spec version: {0}{1}'
    fixscript_h3      = '# Each ffmpeg line is runnable as-is. Lines starting with # are descriptions/notes. Delete unneeded fixes before running'
    fixscript_h4      = '# When one file has multiple fixes, each produces a separate output file. Keep only the ones you need'
    fixscript_none    = '# No files needed fixing'
    fixscript_written = 'Wrote fix commands: {0} (for {1} file(s))'
  }
}

# 表示文字列の取得。未訳キーは日本語にフォールバックする。
# ja/en 双方に無いキーはキー名自体を返す — $null を返すとメッセージが空欄になり、
# 綴り間違いが出力を見ても気付けなくなるため
function T([string]$Key) {
  $t = $Strings[$Lang]
  if ($t.ContainsKey($Key)) { return $t[$Key] }
  if ($Strings['ja'].ContainsKey($Key)) { return $Strings['ja'][$Key] }
  return "<$Key>"
}

# --- ffprobe / ffmpeg の自動検出 ---
# 優先順位: -FFprobePath/-FFmpegPath で明示指定 → PATH → 環境変数 FFMPEG_BIN_DIR
# 環境変数を設定しない場合は PATH 上の ffmpeg/ffprobe を使う (通常はこれで十分)。
function Find-Tool([string]$Name, [string]$Override) {
  if ($Override) {
    if (Test-Path $Override) { return $Override }
    Write-Host ((T 'err_tool_override') -f $Name, $Override) -ForegroundColor Red
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
  Write-Host ((T 'err_tool_notfound') -f $Name) -ForegroundColor Red
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
# --- jasna の仕様 (バージョン別) ---
# 0.8.1 でメディア層が python_vali/PyNvVideoCodec → PyAV に変わり制約が大きく緩んだ一方、
# 奇数解像度という新しい致命傷が加わった。バージョン差は必ずこのテーブルに集約し、
# 判定本体にバージョン分岐の if を散らさないこと
$JasnaSpecs = @{
  "0.7.2" = @{
    # NVDEC でデコードできるコーデック
    HwCodecs      = @("h264", "hevc", "vp9", "av1")
    # NVDEC 必須でソフトウェアフォールバックが無いため処理不能 = FAIL
    CodecSeverity = "FAIL"
    CodecKey      = "codec_unsupported"
    CodecFixKey   = "jasna_reencode"
    # 対応色空間。これ以外は黙って BT.709 に読み替えられる (media/__init__.py:194)
    Colorspaces   = @("bt709", "smpte170m", "bt470bg", "bt601")
    MaxBitDepth   = 10
    # 0.7.2 には rgb_to_nv12.py が無く (rgb_to_p010.py のみ)、偶数解像度の要求は確認できない
    CheckOddDims  = $false
    NegPtsKey     = "neg_pts_jasna"
    # 0.7.2 には splice.py が無く --segments 自体が存在しない
    HasSegments   = $false
  }
  "0.8.1" = @{
    HwCodecs      = @("h264", "hevc", "vp9", "av1")
    # CPU デコードへ黙ってフォールバックする (video_decoder.py:243-257) ため低速化のみ = WARN
    CodecSeverity = "WARN"
    CodecKey      = "codec_slow"
    # 0.8.1 では処理自体は通るため、再エンコードは「必須の修復」ではなく「高速化の任意手段」
    CodecFixKey   = "jasna_reencode_speed"
    # BT.2020 に対応 (pipeline.py:515-526)
    Colorspaces   = @("bt709", "smpte170m", "bt470bg", "bt601", "bt2020nc", "bt2020_ncl")
    MaxBitDepth   = 10
    # rgb_to_nv12.py:70-71 が偶数解像度を要求し、エンコード開始後に ValueError で停止する
    CheckOddDims  = $true
    NegPtsKey     = "neg_pts_jasna_kept"
    HasSegments   = $true
  }
}
$JasnaSpec = $JasnaSpecs[$JasnaVersion]

# jasna のフォルダ走査対象拡張子 (media_files.py:7-9)。単一ファイル指定時はこの検査を通らない
$JasnaScanExtensions = @(".mp4", ".mkv", ".avi", ".mov", ".wmv", ".flv", ".webm")
# 4:2:0 系の pix_fmt。これ以外は jasna 内部で 4:2:0 に間引かれる
$Chroma420PixFmts = @("yuv420p", "yuvj420p", "nv12", "nv21", "yuv420p10le", "p010le", "yuv420p12le")

# --- jasna --segments (スマートレンダリング) の厳格ゲート (splice.py) ---
$SegSmartCodecs  = @("h264", "hevc", "av1")                                             # :20
$SegOutputExts   = @(".mp4", ".mov", ".mkv")                                            # :21
$SegPixFmts      = @("yuv420p", "yuvj420p", "nv12", "yuv420p10le", "p010le")            # :114-119
$SegFieldOrders  = @("unknown", "progressive")                                          # :120-122
$SegH264Profiles = @("baseline", "constrained baseline", "main", "high")                # :22-27

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

# jasna 固有 finding の追加。Scope の綴り間違いを防ぎ、判定ブロックの行を短く保つ
function Add-JasnaFinding($Result, [string]$Severity, [string]$Message, [string]$FixKey = "") {
  Add-Finding $Result $Severity "jasna" $Message $FixKey
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
    Add-Finding $r "FAIL" "common" (T 'file_zero')
    $r.Failed = $true
    return $r
  }

  # --- ffprobe メタデータ ---
  # -show_chapters は jasna がチャプターを黙って捨てる判定に使う。1 回のプローブで
  # profile / pix_fmt / bits_per_raw_sample / start_pts / field_order / color_trc も揃うため
  # 追加のプロセス起動は不要
  $probe = Invoke-FFprobeJson @("-show_format", "-show_streams", "-show_chapters", $p)
  if (-not $probe.Ok) {
    Add-Finding $r "FAIL" "common" ((T 'ffprobe_fail') -f $probe.Stderr) "remux"
    $r.Failed = $true
    return $r
  }
  $fmt = $probe.Json.format
  $vStream = $probe.Json.streams |
    Where-Object { $_.codec_type -eq "video" -and $_.disposition.attached_pic -ne 1 } |
    Select-Object -First 1
  $aStream = $probe.Json.streams | Where-Object { $_.codec_type -eq "audio" } | Select-Object -First 1

  if (-not $vStream) {
    Add-Finding $r "FAIL" "common" (T 'no_video_stream')
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

  # --- jasna 判定に使う追加メタデータ ---
  # ffprobe の JSON キーは color_transfer。color_trc は ffmpeg CLI 側のオプション名で JSON には出ない
  $colorTrc = $vStream.color_transfer
  # $profile は PowerShell の自動変数 ($PROFILE) と衝突するため別名にする
  $vProfile = $vStream.profile
  $startPts = $vStream.start_pts
  # ビット深度。bits_per_raw_sample が無いコンテナも多いので pix_fmt の接尾辞から補う
  $bitDepth = 8
  if ($vStream.bits_per_raw_sample -and "$($vStream.bits_per_raw_sample)" -ne "N/A") {
    $bitDepth = [int]$vStream.bits_per_raw_sample
  } elseif ($vStream.pix_fmt -and $vStream.pix_fmt -match '(\d+)(le|be)$') {
    $bitDepth = [int]$Matches[1]
  }
  # ストリーム構成。jasna は映像 1 本 + 音声のみを muxing 対象にする
  $vCount   = @($probe.Json.streams | Where-Object { $_.codec_type -eq "video" -and $_.disposition.attached_pic -ne 1 }).Count
  $subCount = @($probe.Json.streams | Where-Object { $_.codec_type -eq "subtitle" }).Count
  $datCount = @($probe.Json.streams | Where-Object { $_.codec_type -eq "data" }).Count
  $attCount = @($probe.Json.streams | Where-Object { $_.codec_type -eq "attachment" }).Count
  # chapters プロパティ自体が無いとき @($null).Count は 1 になるため、存在確認を挟む
  $chpCount = 0
  if ($probe.Json.PSObject.Properties.Name -contains 'chapters') {
    $chpCount = @($probe.Json.chapters | Where-Object { $_ }).Count
  }

  $audioDesc = if ($aStream) { $aStream.codec_name } else { T 'audio_none' }
  $fpsDesc = if ($fps) { "{0:0.###}fps" -f $fps } else { T 'fps_unknown' }
  $audioLabel = T 'meta_audio_label'
  $r.MetaLine = "$($File.Extension.TrimStart('.')) / $codec / ${width}x${height} / $pixFmt / $fpsDesc / $(Format-Duration $duration) / ${audioLabel}: $audioDesc"

  # --- 基本メタデータの妥当性 ---
  if (-not $fps -or $fps -le 0) {
    Add-Finding $r "FAIL" "common" ((T 'fps_fail') -f $vStream.r_frame_rate) "remux"
  }
  if ($duration -le 0) {
    Add-Finding $r "WARN" "common" (T 'duration_fail') "remux"
  }
  if ($width -le 0 -or $height -le 0) {
    Add-Finding $r "FAIL" "common" (T 'resolution_fail')
  }

  # --- VFR 検出 ---
  if ($fps -and $avgFps -and $avgFps -gt 0) {
    $diff = [math]::Abs($fps - $avgFps) / $fps
    if ($diff -gt 0.01) {
      Add-Finding $r "WARN" "common" ((T 'vfr_detect') -f $fps, $avgFps) "vfr"
    }
  }

  # --- インターレース ---
  if ($fieldOrder -and $fieldOrder -notin @("progressive", "unknown")) {
    Add-Finding $r "WARN" "common" ((T 'interlace_detect') -f $fieldOrder) "interlace"
  }

  # --- lada-ex: 色レンジ ---
  if (-not $colorRange -or $colorRange -eq "unknown") {
    Add-Finding $r "WARN" "lada" (T 'colorrange_unknown') "range_tag"
  }

  # --- lada-ex: 拡張子 ---
  if ($File.Extension.ToLower() -notin $LadaExtensions) {
    Add-Finding $r "FAIL" "lada" ((T 'ext_unsupported') -f $File.Extension) "remux"
  }

  # =====================================================================
  # jasna 固有の判定 (バージョン差はすべて $JasnaSpec が吸収する)
  # =====================================================================
  $csList = $JasnaSpec.Colorspaces -join "/"

  # 色空間。対応外でも例外にはならず黙って BT.709 に読み替えられる (media/__init__.py) ため、
  # 実害は「処理不能」ではなく「色ずれ」= WARN
  if (-not $colorSpace -or $colorSpace -eq "unknown") {
    Add-JasnaFinding $r "WARN" (T 'colorspace_unset') "color_tag"
  } elseif ($colorSpace -notin $JasnaSpec.Colorspaces) {
    Add-JasnaFinding $r "WARN" ((T 'colorspace_unsupported') -f $colorSpace, $csList) "color_tag"
  }

  # コーデック。0.7.2 は NVDEC 必須で FAIL、0.8.1 は CPU フォールバックで WARN
  if ($codec -notin $JasnaSpec.HwCodecs) {
    Add-JasnaFinding $r $JasnaSpec.CodecSeverity `
      ((T $JasnaSpec.CodecKey) -f $codec, ($JasnaSpec.HwCodecs -join "/")) $JasnaSpec.CodecFixKey
  }

  # 奇数解像度 (0.8.1: rgb_to_nv12.py が偶数を要求。エンコード開始後に停止する)
  if ($JasnaSpec.CheckOddDims -and $width -gt 0 -and $height -gt 0 -and
      (($width % 2) -ne 0 -or ($height % 2) -ne 0)) {
    Add-JasnaFinding $r "FAIL" ((T 'jasna_odd_dims') -f $width, $height) "even_dims"
  }

  # duration 欠落 → メタデータ読み取りで KeyError (両バージョン共通)
  if ($duration -le 0) {
    Add-JasnaFinding $r "FAIL" (T 'jasna_duration_missing') "remux"
  }
  # start_pts 欠落 → GUI プレビューが TypeError (CLI は動く)
  if ($null -eq $startPts -or "$startPts" -eq "N/A") {
    Add-JasnaFinding $r "WARN" (T 'jasna_start_pts_missing') "genpts"
  }

  # HDR。トーンマップされず転送特性が素通しされる
  if ($colorTrc -in @("smpte2084", "arib-std-b67")) {
    Add-JasnaFinding $r "WARN" ((T 'jasna_hdr') -f $colorTrc) "color_convert"
  }

  # インターレース。jasna 側でデインターレースされない
  if ($fieldOrder -and $fieldOrder -notin @("progressive", "unknown")) {
    Add-JasnaFinding $r "WARN" ((T 'jasna_interlace') -f $fieldOrder) "interlace"
  }

  # クロマ / ビット深度。$pixFmt は "?" に既定されるため生の値を見る
  if ($vStream.pix_fmt) {
    if ($vStream.pix_fmt -notin $Chroma420PixFmts) {
      Add-JasnaFinding $r "WARN" ((T 'jasna_chroma') -f $vStream.pix_fmt) "pixfmt_420"
    }
    if ($bitDepth -gt $JasnaSpec.MaxBitDepth) {
      Add-JasnaFinding $r "WARN" `
        ((T 'jasna_bitdepth_reduced') -f $bitDepth, $vStream.pix_fmt, $JasnaSpec.MaxBitDepth) "pixfmt_420"
    }
  }

  # 出力に引き継がれないストリーム
  $dropped = @()
  if ($subCount -gt 0) { $dropped += ((T 'jasna_stream_subtitle')   -f $subCount) }
  if ($datCount -gt 0) { $dropped += ((T 'jasna_stream_data')       -f $datCount) }
  if ($attCount -gt 0) { $dropped += ((T 'jasna_stream_attachment') -f $attCount) }
  if ($chpCount -gt 0) { $dropped += ((T 'jasna_stream_chapter')    -f $chpCount) }
  if ($dropped.Count -gt 0) {
    Add-JasnaFinding $r "WARN" ((T 'jasna_extra_streams') -f ($dropped -join " / "))
  }
  if ($vCount -gt 1) {
    Add-JasnaFinding $r "WARN" ((T 'jasna_multi_video') -f $vCount)
  }

  # フォルダ走査時のみ: jasna 側の拡張子フィルタ。単一ファイル指定はこの検査を通らない
  if ($script:IsFolderScan -and $File.Extension.ToLower() -notin $JasnaScanExtensions) {
    Add-JasnaFinding $r "WARN" `
      ((T 'jasna_ext_folder') -f $File.Extension, ($JasnaScanExtensions -join " ")) "remux"
  }

  # --segments の厳格ゲート (opt-in。0.7.2 には --segments 自体が無いので不活性)
  if ($Segments -and $JasnaSpec.HasSegments) {
    Test-JasnaSegments $r $File $codec $vStream.pix_fmt $fieldOrder $vProfile $bitDepth $fps $avgFps
  }

  # --- lada-ex: time_base ---
  if ($timeBase -eq "1/10000000") {
    Add-Finding $r "WARN" "lada" (T 'timebase_incompatible') "remux"
  }

  # --- 先頭パケット PTS ---
  $pkt = Invoke-FFprobeJson @("-select_streams", "v:0", "-show_packets", "-read_intervals", "%+#1", $p)
  $firstPts = $null
  if ($pkt.Ok -and $pkt.Json.packets -and $pkt.Json.packets.Count -gt 0) {
    $rawPts = $pkt.Json.packets[0].pts
    if ($null -eq $rawPts -or "$rawPts" -eq "N/A") {
      Add-Finding $r "FAIL" "common" (T 'first_pkt_no_pts') "genpts"
    } else {
      $firstPts = [long]$rawPts
    }
  } else {
    Add-Finding $r "FAIL" "common" (T 'first_pkt_unreadable') "remux"
  }

  if ($null -ne $firstPts -and $firstPts -lt 0) {
    $ptsSec = if ($tbVal) { "{0:0.###}s" -f ($firstPts * $tbVal) } else { "?" }
    if ($firstPts -lt -1000) {
      Add-Finding $r "WARN" "lada" ((T 'neg_pts_large') -f $firstPts, $ptsSec) "genpts"
    } else {
      Add-Finding $r "WARN" "lada" ((T 'neg_pts') -f $firstPts) "genpts"
    }
    Add-JasnaFinding $r "WARN" (T $JasnaSpec.NegPtsKey) "genpts"
  }
  if ($null -ne $startTime -and $startTime -lt 0) {
    Add-Finding $r "WARN" "lada" ((T 'neg_start_time') -f $startTime) "genpts"
  }

  # --- standard: 全パケット PTS/DTS スキャン ---
  if ($Level -in @("standard", "full") -and -not $r.Failed) {
    Invoke-PacketScan $r $p $tbVal
  }

  # --- standard: 音声パケットのタイムスタンプ検査 (jasna 対象時のみ) ---
  if ($Level -in @("standard", "full") -and -not $r.Failed -and
      $Target -in @("jasna", "both") -and $aStream) {
    Invoke-AudioPacketScan $r $p
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
    Add-Finding $Result "WARN" "common" (T 'pktscan_fail')
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
    Add-Finding $Result "FAIL" "common" ((T 'pktscan_missing_pts') -f $missingPts, $total) "genpts"
  }
  if ($negativePts -gt 1) {
    Add-Finding $Result "WARN" "common" ((T 'pktscan_neg_pts') -f $negativePts) "genpts"
  }
  if ($dupPts -gt 0) {
    Add-Finding $Result "FAIL" "common" ((T 'pktscan_dup_pts') -f $dupPts) "genpts"
  }
  if ($dtsBackward -gt 0) {
    Add-Finding $Result "FAIL" "common" ((T 'pktscan_dts_backward') -f $dtsBackward) "genpts"
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
        Add-Finding $Result "WARN" "lada" ((T 'pktscan_gap') -f $gapCount, ($maxGap * $TimeBaseValue)) "vfr"
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
    Add-Finding $Result "FAIL" "common" ((T 'decode_error') -f $errors.Count, $sample) "reencode_broken"
  }
}

# --- 音声パケットのタイムスタンプ検査 (standard / full、jasna 対象時のみ) ---
# jasna は pts/dts の双方が無い音声パケットを黙って破棄する (video_encoder.py:609-611)
function Invoke-AudioPacketScan($Result, [string]$FilePath) {
  $ErrorActionPreference = "Continue"  # PS5.1: stderr リダイレクトでの NativeCommandError 停止を防ぐ
  $lines = & $FFprobe -v error -select_streams a:0 -show_entries packet=pts,dts -of csv=p=0 $FilePath 2>$null
  # 音声トラックが読めないケースは映像側のスキャンとコンテナ判定で既にカバーされる。
  # ここで別の finding を足しても情報が増えないため無言で戻る
  if ($LASTEXITCODE -ne 0 -or -not $lines) { return }
  $noTs = 0
  foreach ($line in $lines) {
    if (-not $line) { continue }
    $parts = $line.Split(",")
    $ptsStr = $parts[0]
    $dtsStr = if ($parts.Count -gt 1) { $parts[1] } else { "N/A" }
    if (($ptsStr -eq "N/A" -or $ptsStr -eq "") -and ($dtsStr -eq "N/A" -or $dtsStr -eq "")) { $noTs++ }
  }
  if ($noTs -gt 0) {
    Add-JasnaFinding $Result "WARN" ((T 'jasna_audio_no_ts') -f $noTs) "genpts"
  }
}

# --- jasna --segments (スマートレンダリング) の厳格ゲート (splice.py) ---
# 通常経路よりも条件が厳しく、外れるとフル再エンコードに落ちるのではなく処理が拒否される。
# 判定は抽出済みメタデータのみで行うため ffprobe の追加呼び出しは無い
function Test-JasnaSegments($Result, $File, [string]$Codec, [string]$PixFmt,
                            [string]$FieldOrder, [string]$VProfile, [int]$BitDepth, $Fps, $AvgFps) {
  if ($Codec -notin $SegSmartCodecs) {
    Add-JasnaFinding $Result "FAIL" ((T 'seg_codec') -f $Codec, ($SegSmartCodecs -join "/")) "jasna_reencode"
  }
  if ($PixFmt -and $PixFmt -notin $SegPixFmts) {
    Add-JasnaFinding $Result "FAIL" ((T 'seg_pixfmt') -f $PixFmt, ($SegPixFmts -join "/")) "pixfmt_420"
  }
  if ($FieldOrder -and $FieldOrder -notin $SegFieldOrders) {
    Add-JasnaFinding $Result "FAIL" ((T 'seg_field_order') -f $FieldOrder) "interlace"
  }
  if ($Codec -eq "h264") {
    if ($BitDepth -gt 8) {
      Add-JasnaFinding $Result "FAIL" (T 'seg_h264_10bit') "pixfmt_420"
    }
    # ffprobe は "High" / "Constrained Baseline" と返すため小文字化して比較する
    if ($VProfile -and $VProfile.ToLower() -notin $SegH264Profiles) {
      Add-JasnaFinding $Result "FAIL" ((T 'seg_h264_profile') -f $VProfile, ($SegH264Profiles -join "/")) "jasna_reencode"
    }
  }
  # CFR 必須。共通の VFR 検出 (1%) より厳しい 0.1% なので両方出ることがある
  if ($Fps -and $Fps -gt 0 -and $AvgFps -and $AvgFps -gt 0) {
    $devPct = [math]::Abs($Fps - $AvgFps) / $Fps * 100
    if ($devPct -gt 0.1) {
      Add-JasnaFinding $Result "FAIL" ((T 'seg_vfr') -f $devPct) "vfr"
    }
  }
  if ($File.Extension.ToLower() -notin $SegOutputExts) {
    Add-JasnaFinding $Result "WARN" ((T 'seg_ext') -f ($SegOutputExts -join "/"), $File.Extension)
  }
}

# =====================================================================
# 修復コマンドの提示
# =====================================================================
function Get-FixSuggestion([string]$FixKey, $Result) {
  $p = $Result.File.FullName
  $stem = Join-Path $Result.File.DirectoryName $Result.File.BaseName
  switch ($FixKey) {
    "genpts" { (T 'fix_genpts') -f $p, $stem }
    "remux"  { (T 'fix_remux')  -f $p, $stem }
    "jasna_reencode" {
      $deint = if ($Result.Findings | Where-Object { $_.FixKey -eq "interlace" }) { ' -vf bwdif' } else { '' }
      (T 'fix_jasna_reencode') -f $p, $stem, $deint
    }
    "jasna_reencode_speed" {
      $deint = if ($Result.Findings | Where-Object { $_.FixKey -eq "interlace" }) { ' -vf bwdif' } else { '' }
      (T 'fix_jasna_reencode_speed') -f $p, $stem, $deint
    }
    "color_convert" { (T 'fix_color_convert') -f $p, $stem }
    "color_tag" {
      if ($Result.Codec -in @("h264", "hevc")) {
        $bsf = "$($Result.Codec)_metadata"
        (T 'fix_color_tag_meta') -f $p, $stem, $bsf
      } else {
        (T 'fix_color_tag_reencode') -f $p, $stem, $Result.Codec
      }
    }
    "range_tag" {
      if ($Result.Codec -in @("h264", "hevc")) {
        $bsf = "$($Result.Codec)_metadata"
        (T 'fix_range_tag_meta') -f $p, $stem, $bsf
      } else {
        (T 'fix_range_tag_reencode') -f $p, $stem, $Result.Codec
      }
    }
    "vfr"             { (T 'fix_vfr')             -f $p, $stem }
    "interlace"       { (T 'fix_interlace')       -f $p, $stem }
    "reencode_broken" { (T 'fix_reencode_broken') -f $p, $stem }
    "even_dims"       { (T 'fix_even_dims')       -f $p, $stem }
    "pixfmt_420"      { (T 'fix_pixfmt_420')      -f $p, $stem }
    default { $null }
  }
}

# =====================================================================
# レポート出力
# =====================================================================
# 判定はロジック用の正準値 (OK / WARN / FAIL) を返す。表示は Get-VerdictLabel で言語別に写像する
function Get-Verdict($Result, [string]$ToolScope) {
  $relevant = $Result.Findings | Where-Object { $_.Scope -in @("common", $ToolScope) }
  if ($relevant | Where-Object { $_.Severity -eq "FAIL" }) { return "FAIL" }
  if ($relevant | Where-Object { $_.Severity -eq "WARN" }) { return "WARN" }
  return "OK"
}

function Get-VerdictColor([string]$Verdict) {
  switch ($Verdict) { "FAIL" { "Red" } "WARN" { "Yellow" } default { "Green" } }
}

# jasna 仕様バージョン行に付ける --segments 注記。コンソールと修復スクリプトで共用する
function Get-SegmentsNote() {
  if ($Segments -and $JasnaSpec.HasSegments) { return T 'segments_suffix' }
  return ""
}

function Get-VerdictLabel([string]$Verdict) {
  switch ($Verdict) { "FAIL" { T 'verdict_fail' } "WARN" { T 'verdict_warn' } default { T 'verdict_ok' } }
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
    Write-Host "  $(T 'label_metadata'): $($Result.MetaLine)"
  }

  if ($Result.Findings.Count -eq 0) {
    Write-Host "  [OK]   $(T 'no_problems')" -ForegroundColor Green
  } else {
    foreach ($f in $Result.Findings) {
      $tag = if ($f.Severity -eq "FAIL") { "[FAIL]" } else { "[WARN]" }
      $color = if ($f.Severity -eq "FAIL") { "Red" } else { "Yellow" }
      # jasna はバージョンで判定基準が変わるため、スコープラベルにバージョンを載せる
      $scopeLabel = switch ($f.Scope) {
        "lada"  { T 'scope_lada' }
        "jasna" { (T 'scope_jasna') -f $JasnaVersion }
        default { "" }
      }
      Write-Host "  $tag $scopeLabel$($f.Message)" -ForegroundColor $color
    }
  }

  # 判定行
  $verdictParts = @()
  if ($Target -in @("lada", "both"))  { $verdictParts += "$(T 'label_lada') → $(Get-VerdictLabel (Get-Verdict $Result 'lada'))" }
  if ($Target -in @("jasna", "both")) { $verdictParts += "$((T 'label_jasna') -f $JasnaVersion) → $(Get-VerdictLabel (Get-Verdict $Result 'jasna'))" }
  Write-Host "  $(T 'label_verdict'): $($verdictParts -join ' / ')" -ForegroundColor White

  # 対処コマンド (対象ツールに関係する findings の FixKey を重複排除して提示)
  $fixKeys = Get-RelevantFixKeys $Result
  if ($fixKeys) {
    Write-Host ""
    Write-Host "  $(T 'label_fixes')" -ForegroundColor Magenta
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
# ffmpeg の行はそのまま実行可能な行として、説明 (例: [PTS 異常] ...) や注記 (※ / Note: ...) は
# # コメントとして書き出す。出力先が .ps1 ならそのまま実行、コピペでの利用も可能。
# 日本語コメントを含むため、PS5.1 で実行/編集しても壊れないよう UTF-8 BOM 付きで保存する。
function Write-FixScriptFile($Results, [string]$OutPath) {
  $full = if ([System.IO.Path]::IsPathRooted($OutPath)) { $OutPath }
          else { Join-Path (Get-Location).Path $OutPath }

  $sb = [System.Collections.Generic.List[string]]::new()
  $sb.Add((T 'fixscript_h1'))
  $sb.Add(((T 'fixscript_h2') -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Target, $Level))
  if ($Target -in @("jasna", "both")) {
    $sb.Add(((T 'fixscript_h2b') -f $JasnaVersion, (Get-SegmentsNote)))
  }
  $sb.Add((T 'fixscript_h3'))
  $sb.Add((T 'fixscript_h4'))
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
    $sb.Add((T 'fixscript_none'))
  }

  $content = ($sb -join "`r`n") + "`r`n"
  $enc = New-Object System.Text.UTF8Encoding($true)  # BOM 付き
  [System.IO.File]::WriteAllText($full, $content, $enc)
  Write-Host ""
  Write-Host ((T 'fixscript_written') -f $full, $count) -ForegroundColor Green
}

# =====================================================================
# メイン
# =====================================================================
if (-not (Test-Path $Path)) {
  Write-Host ((T 'err_path_notfound') -f $Path) -ForegroundColor Red
  exit 2
}

$files = @()
$item = Get-Item $Path
# jasna のフォルダ走査は拡張子でフィルタされるが単一ファイル指定は素通しになるため、
# どちらの経路かを Test-VideoFile から参照できるようにしておく
$script:IsFolderScan = $item.PSIsContainer
if ($item.PSIsContainer) {
  $files = Get-ChildItem -Path $Path -File -Recurse:$Recurse |
    Where-Object { $_.Extension.ToLower() -in $ScanExtensions } |
    Sort-Object FullName
  if (-not $files) {
    Write-Host ((T 'err_no_video') -f $Path) -ForegroundColor Red
    exit 2
  }
} else {
  $files = @($item)
}

Write-Host ((T 'scan_target') -f $files.Count, $Target, $Level) -ForegroundColor White
if ($Target -in @("jasna", "both")) {
  Write-Host ((T 'scan_jasna_spec') -f $JasnaVersion, (Get-SegmentsNote)) -ForegroundColor White
}

$results = @()
foreach ($f in $files) {
  $results += Test-VideoFile $f
  Write-FileReport $results[-1]
}

# --- サマリ (複数ファイル時のみ) ---
if ($results.Count -gt 1) {
  Write-Host ""
  Write-Host (T 'summary_header') -ForegroundColor Cyan
  # Format-Table は使わない。長い日本語ファイル名がコンソール幅を使い切ると
  # AutoSize が判定列を黙って切り捨てるため。判定を先頭に置き 1 ファイル 1 行で出す
  # 判定ラベルの埋め幅は言語で変わる (英語の CAUTION 等は日本語より長い) ため、
  # 当該言語の最大ラベル長 +1 を列幅にして次の項目と密着しないようにする
  $padW = (@((T 'verdict_ok'), (T 'verdict_warn'), (T 'verdict_fail')) |
           Measure-Object -Property Length -Maximum).Maximum + 1
  foreach ($res in $results) {
    Write-Host "  " -NoNewline
    if ($Target -in @("lada", "both")) {
      $v = Get-Verdict $res "lada"
      Write-Host "$(T 'label_lada'):" -NoNewline
      Write-Host (Get-VerdictLabel $v).PadRight($padW) -NoNewline -ForegroundColor (Get-VerdictColor $v)
    }
    if ($Target -in @("jasna", "both")) {
      $v = Get-Verdict $res "jasna"
      Write-Host "$((T 'label_jasna') -f $JasnaVersion):" -NoNewline
      Write-Host (Get-VerdictLabel $v).PadRight($padW) -NoNewline -ForegroundColor (Get-VerdictColor $v)
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
