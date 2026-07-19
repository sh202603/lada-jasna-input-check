# Check-VideoInput for lada-ex / jasna

**日本語** | [English](README.en.md)

Version: 1.2.0

[lada-ex](https://codeberg.org/comman/lada-ex) / [jasna](https://github.com/Kruk2/jasna) に投入する動画を、処理を始める前に検査する PowerShell 製のツールです。

ffprobe / ffmpeg を使って動画のメタデータ・PTS/DTS・ビットストリームを調べ、両ツールの仕様 (コンテナ / コーデック / 色空間) に合っているか、PTS の壊れ (欠落・負値・重複・逆行・大きなギャップ) が無いかを事前に確認します。問題が見つかった場合は、その原因の説明とあわせて、**そのままコピー&ペーストして実行できる修復用の ffmpeg コマンド**を提示します。(対処コマンドのファイル書き出しも可)

処理に失敗する動画・音ズレする動画・色がずれる動画を、本処理にかける前に見つけ出すことを目的としています。

---

## こんなときに使います

- lada-ex / jasna に動画を入れたら、エラーで止まってしまう
- 処理は通ったのに、音と映像がずれてしまう／色がおかしくなる
- 大量の動画を処理する前に、問題のあるファイルだけ先に洗い出しておきたい

---

## クイックスタート（GitHub やコマンドラインに不慣れな方向け）

3 つのステップで使い始められます。順番に進めてください。

### ステップ 1：ffmpeg を用意する

このツールは動画の検査に **ffmpeg / ffprobe** を使います。まず、すでに入っているか確認しましょう。

1. スタートメニューで「PowerShell」または「ターミナル」を開きます。
2. 次のように入力して Enter を押します。

   ```powershell
   ffmpeg -version
   ```

3. バージョン情報が表示されれば準備済みです。ステップ 2 に進んでください。

「`ffmpeg` は認識されません」などと表示された場合は、以下のいずれかで導入します。

**かんたんな方法（Windows 11）** — 次のコマンドを実行します。

```powershell
winget install Gyan.FFmpeg
```

インストール後、**いったんターミナルを閉じて開き直してから**、もう一度 `ffmpeg -version` で確認してください。

**手動で入れる方法** — [ffmpeg.org](https://ffmpeg.org/download.html) から Windows 用のビルドをダウンロードして展開し、`bin` フォルダ（`ffmpeg.exe` / `ffprobe.exe` が入っている場所）を PATH に追加します。PATH の設定が難しい場合は、後述の `FFMPEG_BIN_DIR` を使う方法でも構いません。

### ステップ 2：このツールをダウンロードする

**かんたんな方法（ZIP でダウンロード）**

1. このページの上のほうにある緑色の **「Code」** ボタンを押します。
2. 表示されたメニューの **「Download ZIP」** を選びます。
3. ダウンロードした ZIP ファイルを右クリックして「すべて展開」し、好きな場所（例：デスクトップ）に置きます。

**git を使う方法（git を入れている方向け）**

```powershell
git clone https://github.com/sh202603/lada-jasna-input-check.git
```

### ステップ 3：動画を検査する

1. 展開したフォルダ（`Check-VideoInput.ps1` が入っているフォルダ）を開きます。
2. フォルダ内の何もないところで **右クリック → 「ターミナルで開く」** を選びます。
3. 開いたウィンドウに、次のように入力して Enter を押します。`"..."` の部分は、検査したい動画ファイルのパスに置き換えてください（動画ファイルをウィンドウにドラッグ&ドロップすると、パスが自動で入力されます）。

   PowerShell（ターミナル）の場合:

   ```powershell
   .\Check-VideoInput.ps1 "C:\Users\you\Videos\sample.mp4"
   ```

   コマンドプロンプト（cmd）の場合は、付属の `Check-VideoInput.bat` を使います（実行ポリシーの設定は不要です）:

   ```bat
   Check-VideoInput.bat "C:\Users\you\Videos\sample.mp4"
   ```

4. しばらく待つと、検査結果と、問題があれば対処コマンドが表示されます。

> **コマンドプロンプト（cmd）から使いたい場合**、または PowerShell の実行ポリシーでブロックされてしまう場合は、付属の `Check-VideoInput.bat` を使ってください。実行ポリシーの設定なしで動きます。
>
> ```bat
> Check-VideoInput.bat "C:\Users\you\Videos\sample.mp4"
> ```
>
> なお、`Check-VideoInput.bat` に動画ファイルをドラッグ&ドロップしても検査できますが、結果ウィンドウが終了時に閉じてしまいます。結果をゆっくり読みたいときは、上記のようにターミナルから実行してください。

### 結果の読み方

- **判定が「OK」** … そのまま lada-ex / jasna に投入して問題ありません。
- **判定が「注意」** … 処理はできますが、低速化や音ズレなどのリスクがあります。気になる場合は表示された対処コマンドを実行してください。
- **判定が「NG」** … 仕様に合わない、または壊れている可能性のある問題が見つかった状態です。必ず処理に失敗するとは限らず、問題が軽微であればそのまま通ることもあります。ただし途中で失敗したり、処理後の動画がカクつく・音がずれる・色がずれるといった問題が出る可能性があります。安心して処理にかけるには、表示された対処コマンドで直してから投入することをおすすめします。

フォルダごとまとめて検査したいときは、ファイルのパスの代わりにフォルダのパスを指定します（サブフォルダも含めるには `-Recurse` を付けます）。

```powershell
.\Check-VideoInput.ps1 "C:\Users\you\Videos" -Recurse
```

---

## 前提条件

- Windows 11（動作保証の対象です。Windows 10 は対象外です。動く可能性はありますが検証していません）
- Windows PowerShell 5.1、または PowerShell 7 以降（どちらでも動作します）
- `ffprobe` / `ffmpeg`（検査と修復コマンドの生成に使用します）

ffprobe / ffmpeg は、次の順番で探します。

1. `-FFprobePath` / `-FFmpegPath` で明示的に指定した場所
2. PATH に登録されている `ffmpeg` / `ffprobe`
3. 環境変数 `FFMPEG_BIN_DIR` で指定したディレクトリ

通常は ffmpeg を PATH に通しておけば十分です。PATH に入れたくない場合は、環境変数 `FFMPEG_BIN_DIR` に ffmpeg / ffprobe の置き場所（例：`C:\ffmpeg\bin`）を設定してください。

---

## 詳しい使い方

```powershell
.\Check-VideoInput.ps1 <ファイル|フォルダ> [オプション]

# 例
.\Check-VideoInput.ps1 D:\videos\sample.mp4
.\Check-VideoInput.ps1 D:\videos -Recurse -Target jasna -Level full
```

コマンドプロンプト（cmd）からは `Check-VideoInput.bat` を使います。

```bat
Check-VideoInput.bat D:\videos\sample.mp4 -Level full
```

このラッパーは次のように動作します。

- `where pwsh.exe` で PowerShell 7（pwsh）を探し、あればそれを、無ければ Windows 標準の powershell.exe（5.1）を使って実行します。
- 同じフォルダにある `Check-VideoInput.ps1` を `-NoProfile -ExecutionPolicy Bypass -File` で起動するため、実行ポリシーの設定は不要です。
- 渡した引数（`%*`）と終了コード（0/1/2）をそのまま引き継ぎます。

### パラメータ

| パラメータ | 値 | 既定 | 説明 |
|---|---|---|---|
| `-Path`（位置 0、必須） | ファイル or フォルダ | — | フォルダを指定すると、対象拡張子の動画をまとめて検査します |
| `-Target` | `lada` / `jasna` / `both` | `both` | 判定の基準とするツールです。判定行・対処・終了コードに影響します |
| `-Level` | `quick` / `standard` / `full` | `standard` | 検査の深さです（下表） |
| `-JasnaVersion` | `0.7.2` / `0.8.1` | `0.8.1` | 判定の基準とする jasna のバージョンです。0.8.1 でメディア層が PyAV に移行し入力制約が大きく変わったため切り替えます。`-Target` が `jasna` / `both` のときのみ意味を持ちます |
| `-Segments` | スイッチ | off | jasna の `--segments`（スマートレンダリング）を使う前提で、追加の厳格チェックを行います。0.8.1 のみ有効で、0.7.2 では何もしません |
| `-Lang` | `ja` / `en` / `auto` | `auto` | 表示言語です。`auto` は OS のカルチャが日本語なら日本語、それ以外は英語で表示します（判定・終了コードは言語に依存しません） |
| `-Recurse` | スイッチ | off | フォルダのサブディレクトリも対象にします |
| `-FixScript` | 出力ファイルのパス | — | 表示した対処コマンドを、後でまとめて実行できる 1 つのファイルに書き出します（下記） |
| `-FFprobePath` / `-FFmpegPath` | パス | 自動検出 | ffprobe / ffmpeg の場所を明示的に指定します |
| `-Version` | スイッチ | — | ツールのバージョンを表示して終了します（検査は行いません。ffmpeg / ffprobe が未導入でも動作します） |

### 対処コマンドをファイルに書き出す（`-FixScript`）

`-FixScript <出力ファイル>` を付けると、画面に表示される対処コマンドを 1 つのファイルにまとめて書き出します。検査したすべてのファイル分（複数指定・フォルダ指定時はその全件）をまとめるので、後で内容を確認しながら PowerShell で一括実行したいときに便利です。

```powershell
.\Check-VideoInput.ps1 D:\videos -Recurse -FixScript fixes.ps1
```

- `ffmpeg ...` の行はそのまま実行可能な形（実際のファイルパス入り）で出力されます。問題の説明（`# [PTS 異常] ...`）や注記（`# ※ ...`）は `#` コメントとして出力されるため、出力先を `.ps1` にすればそのまま PowerShell スクリプトとして実行できます。
- 各 ffmpeg コマンドが作る修復済み動画は、入力の拡張子にかかわらず `.mkv`（`元のファイル名_<サフィックス>.mkv`）になります（理由は[出力先が常に `.mkv` である理由](#出力先が常に-mkv-である理由)）。なお `-FixScript` 自体の出力ファイル（このスクリプト）の拡張子は任意に指定できます。
- ファイルごとに区切りコメント（ファイル名・メタデータ）が入ります。対処が不要だったファイルは含まれません。
- **同一ファイルに複数の対処がある場合は、それぞれ別の出力ファイルを作る内容になっています**。すべてを順に実行すると元ファイルから複数の修復版ができるため、実行前に不要な行を削除して、必要な対処だけを残してください。
- 出力ファイルは UTF-8（BOM 付き）で保存されます。`-FixScript` を付けても画面表示・終了コードは変わりません。
  - これは、生成したスクリプトを Windows PowerShell 5.1 で実行・編集しても日本語コメントが壊れないようにするためです（BOM が無いと 5.1 は CP932 として誤読します）。
  - **Shift_JIS（CP932）固定で開くエディタを使う場合は注意してください。** 多くのエディタは BOM や内容から UTF-8 を自動判別しますが、判別せず Shift_JIS として読み込むと日本語が文字化けし、先頭行に BOM がゴミ文字（`` 等）として見えることがあります。その場合は **エンコードを UTF-8 に指定して開き直してください**。
  - 文字化けの対象は日本語コメントだけではありません。**入力ファイル名が日本語の場合、`ffmpeg ...` のコマンド行にも日本語のパスが入ります**（入力パス、および出力先の `元のファイル名_<サフィックス>.mkv`）。ファイル全体が UTF-8（BOM 付き）なので、そのまま PowerShell（5.1 / 7 のどちらでも）で実行すれば日本語パスは正しく ffmpeg に渡ります。
  - エディタで編集して**保存し直すときは UTF-8 のままにしてください**。Shift_JIS で保存し直すと、PowerShell 7 が既定の UTF-8 として読み込んだ際に日本語パスが文字化けし、実行に失敗します（PowerShell 5.1 は CP932 として読むため Shift_JIS でも動きますが、環境差をなくすため UTF-8 推奨です）。

### チェックレベル

| Level | 内容 | 目安の速度 |
|---|---|---|
| `quick` | ffprobe のメタデータ + 先頭パケットのみ（lada-ex 本体と同等の検査範囲） | 数秒/本 |
| `standard`（既定） | quick + 全パケットの PTS/DTS スキャン（`ffprobe -show_entries packet=pts,dts`） | 数 GB で数十秒 |
| `full` | standard + 全フレームのデコード検証（`ffmpeg -v error -f null -`）。ビットストリーム破損も検出します | 実時間の数分の一 |

### 終了コード

| コード | 意味 |
|---|---|
| 0 | 対象ツールに関係する問題はありませんでした |
| 1 | WARN のみ（処理は可能ですが、低速化や同期ずれなどのリスクがあります） |
| 2 | FAIL あり（処理が失敗するか、処理が通っても再生のカクつき・同期ずれ・色ずれなどの問題が出る可能性があります）、またはツール／パス自体のエラー |

`-Target` で絞った場合、対象外のツール専用の検出結果は終了コードに影響しません。バッチ処理などから連結する例を挙げます。

- PowerShell: `pwsh -File Check-VideoInput.ps1 $file && lada-cli ...`
- cmd: `Check-VideoInput.bat "%file%" && lada-cli ...`

### フォルダ走査の対象拡張子

lada-ex の対応リストに、一般的な動画拡張子を加えたものです。

`.asf .avi .m4v .mkv .mov .mp4 .mpeg .mpg .ts .wmv .webm .rmvb .vob .3gp .flv .m2ts .mts`

（ファイルを 1 つだけ指定した場合は、拡張子に関係なく検査します）

---

## チェック項目

### 共通（quick で実施）

| # | 項目 | 判定 | 修復キー |
|---|---|---|---|
| 1 | ファイルサイズが 0 | FAIL | — |
| 2 | ffprobe が解析に失敗（コンテナ破損） | FAIL | remux |
| 3 | 映像ストリームが無い | FAIL | — |
| 4 | フレームレートが取得できない（`r_frame_rate` の分母 0 など） | FAIL | remux |
| 5 | duration が取得できない | WARN | remux |
| 6 | 解像度が取得できない | FAIL | — |
| 7 | VFR の可能性（`r_frame_rate` と `avg_frame_rate` の差が 1% 超） | WARN | vfr |
| 8 | インターレース（`field_order` が progressive/unknown 以外） | WARN | interlace |
| 9 | 先頭パケットの PTS が N/A（壊れた AVI のパターン） | FAIL | genpts |
| 10 | 先頭パケットが読み取れない | FAIL | remux |

### standard で追加（全パケットスキャン）

映像ストリームの全パケットの pts/dts を CSV ストリームで解析します。

| 項目 | 判定 | 根拠 |
|---|---|---|
| PTS の無いパケット | FAIL | フレームの時刻が決められず、AV 同期が破綻します |
| 負の PTS のパケット（2 個以上） | WARN | 先頭欠け・同期ずれの原因になります |
| PTS の重複 | FAIL | 同時刻フレームの混在＝ mux 不良です（少数ならそのまま通ることも多く、多いとカクつき・同期ずれの原因になります） |
| DTS の逆行 | FAIL | デコード順が破綻し、シーク／デコードが不安定になります |
| ソート後の PTS の大きなギャップ | WARN (lada) | lada-ex で AV 同期がずれる既知の原因です |

大きなギャップの閾値は `max(中央値フレーム間隔 × 4, 0.5 秒)` です。PTS は B フレームのために非単調になるのが正常なので、単調性は DTS で判定し、PTS はソート後のギャップで判定します。

### full で追加（デコード検証）

`ffmpeg -v error -i <file> -map 0:v:0 -f null -` を実行し、エラー出力があれば FAIL とします（件数と先頭 3 件を表示します）。

### lada-ex 固有の判定

| 項目 | 判定 | 根拠 |
|---|---|---|
| 拡張子がホワイトリスト外 | FAIL | lada-ex の対応拡張子リストに含まれません |
| `first_pts < -1000` | WARN | Intel QSV のドライバクラッシュ回避のため VAAPI に強制されます |
| `first_pts < 0` / `start_time < 0` | WARN | TorchCodec → PyAV フォールバック（低速化）が発生します |
| `time_base == 1/10000000` | WARN | TorchCodec の exact seek と非互換のため PyAV にフォールバックします |
| `color_range` が不明 | WARN | 推定できない場合 PyAV にフォールバックします |
| VFR + PTS の大きなギャップ | WARN | AV 同期がずれる既知の原因です |

### jasna 固有の判定

jasna 0.8.1 でメディア層が python_vali/PyNvVideoCodec から **PyAV に全面移行**し、入力に対する制約が大きく変わりました。そのため `-JasnaVersion` で判定基準を切り替えます（既定は `0.8.1`）。

| 項目 | 0.7.2 | 0.8.1 | 根拠 |
|---|---|---|---|
| コーデックが h264/hevc/vp9/av1 以外 | **FAIL** | WARN | 0.7.2 は NVDEC 必須で処理不能。0.8.1 は CPU デコードへ自動フォールバックするため、実害は低速化のみです |
| `color_space` が対応外 | WARN | WARN | 0.8.1 は BT.2020 に対応しました。**どちらのバージョンでも未知のタグは例外にならず黙って BT.709 に読み替えられる**ため、実害は停止ではなく色ずれです |
| `color_space` が未設定 | WARN | WARN | 同上（黙って BT.709 として扱われます） |
| 幅または高さが奇数 | — | **FAIL** | 0.8.1 は NV12 変換が偶数の解像度を要求し、**エンコード開始後に**停止します |
| `duration` が取得できない | **FAIL** | **FAIL** | メタデータ読み取り時に `KeyError` で停止します |
| `start_pts` が無い | WARN | WARN | GUI プレビューが `TypeError` で停止します（CLI での実行は可能です） |
| HDR（PQ / HLG） | WARN | WARN | トーンマップが行われず転送特性がそのまま通るため、白飛び／暗転します |
| インターレース | WARN | WARN | jasna 側でデインターレースされません |
| 4:2:0 以外のクロマ（4:2:2 / 4:4:4 / RGB） | WARN | WARN | 4:2:0 に間引かれ、色解像度が失われます |
| 10bit を超えるビット深度 | WARN | WARN | 10bit に落として処理されます |
| 負の PTS のパケット | WARN | WARN | 0.7.2 は破棄（先頭欠け）。0.8.1 は破棄せず原点を 0 に平行移動します |
| 字幕 / データ / 添付 / チャプター | WARN | WARN | 出力に引き継がれず失われます（映像 1 本 + 音声のみが muxing 対象） |
| 映像ストリームが複数 | WARN | WARN | 先頭の 1 本のみ処理されます |
| 音声パケットに PTS/DTS が無い | WARN | WARN | 該当パケットは破棄されます（`standard` 以上で検査） |
| フォルダ走査の対象外拡張子 | WARN | WARN | jasna のフォルダ走査は `.mp4 .mkv .avi .mov .wmv .flv .webm` のみが対象です。ファイルを個別に指定すれば処理できます（フォルダ指定時のみ検出） |

> `duration` の欠落を FAIL としたため、以前のバージョンで終了コード 1 だったファイルが 2 になる場合があります。

### `--segments` を使う場合の追加チェック（`-Segments`）

jasna の `--segments`（スマートレンダリング）は通常の処理経路よりも制約が厳しく、外れるとフル再エンコードに落ちるのではなく**処理が拒否されます**。`-Segments` を付けると以下を追加で検査します（出力コンテナの項目のみ WARN、他は FAIL）。

| 項目 | 内容 |
|---|---|
| コーデック | `h264` / `hevc` / `av1` のみ |
| `pix_fmt` | `yuv420p` / `yuvj420p` / `nv12` / `yuv420p10le` / `p010le` のみ |
| インターレース | プログレッシブのみ |
| 10bit の H.264 | 非対応 |
| H.264 の profile | `baseline` / `constrained baseline` / `main` / `high` のみ |
| フレームレート | CFR 必須（`r_frame_rate` と `avg_frame_rate` の差が 0.1% 以内。共通の VFR 検出より厳しい閾値です） |
| 入力の拡張子 | 出力コンテナは `.mp4` / `.mov` / `.mkv` のみのため、それ以外なら出力の拡張子を明示する必要があります |

0.7.2 には `--segments` 自体が存在しないため、`-JasnaVersion 0.7.2` と併用しても何も追加されません。

---

## 出力の例

ファイルごとに、次のように表示します。

```
チェック対象: 1 ファイル / Target=both / Level=quick
jasna 仕様バージョン: 0.8.1

=== sample.mp4 ===
  メタデータ: mp4 / h264 / 1921x1080 / yuv420p / 29.97fps / 0:12:34 / 音声: aac
  [WARN] (lada-ex) 負の開始 PTS (first_pts=-2002)。...
  [FAIL] (jasna 0.8.1) 幅または高さが奇数 (1921x1080)。jasna は NV12 変換で偶数の解像度を要求するため ...
  判定: lada-ex → 注意 / jasna 0.8.1 → NG

  --- 対処 ---
  [PTS 異常] PTS を再生成して mkv に remux (無劣化・高速):
    ffmpeg -fflags +genpts -i "..." -map 0 -map -0:d -c copy -avoid_negative_ts make_zero "..._fixed.mkv"
```

- 判定は、FAIL があれば `NG`、WARN のみなら `注意`、何も無ければ `OK` です。
- スコープのラベルは、共通項目には付かず、ツール固有の項目には `(lada-ex)` / `(jasna <バージョン>)` が付きます。jasna はバージョンで判定基準が変わるため、どちらの基準で判定したかがラベルと判定行に表示されます。
- 複数ファイルを検査したときは、最後にサマリ（1 ファイル 1 行で lada-ex / jasna の判定・ファイル名・主な問題）を表示します。判定は NG=赤 / 注意=黄 / OK=緑で色分けされます。
- 対処コマンドは実際のファイルパス入りで生成され、出力先は `元のファイル名_<サフィックス>.mkv`（同じフォルダ）になります。

---

## 修復コマンド一覧

| キー | 対象の問題 | 提示する内容 | 劣化 |
|---|---|---|---|
| genpts | PTS の欠落／負値／重複、DTS の逆行 | `-fflags +genpts ... -c copy -avoid_negative_ts make_zero` で mkv に remux | 無劣化 |
| remux | コンテナ破損・拡張子非対応・メタデータ欠落 | `-c copy` で mkv に remux（`-err_detect ignore_err` の注記付き） | 無劣化 |
| jasna_reencode | jasna 非対応のコーデック（0.7.2）、`--segments` 非対応のコーデック | `hevc_nvenc` で再エンコード。インターレース検出時は `-vf bwdif` を自動付与 | 再エンコード |
| jasna_reencode_speed | jasna 0.8.1 のハードウェアデコード対象外のコーデック | 同上。ただし処理自体は通るため**対処は任意**である旨を明記 | 再エンコード |
| even_dims | 幅または高さが奇数 | `crop=trunc(iw/2)*2:trunc(ih/2)*2` で偶数化して再エンコード（`pad` での代替も注記） | 再エンコード |
| pixfmt_420 | 4:2:0 以外のクロマ、ビット深度の超過 | `-vf format=yuv420p` で 8bit 4:2:0 に変換して再エンコード | 再エンコード |
| color_convert | HDR（PQ / HLG）素材 | zscale + tonemap で BT.709 化（SDR 素材向けの軽量版も注記） | 再エンコード |
| color_tag | 色空間タグの欠落 | h264/hevc は `*_metadata` bsf で無劣化のタグ書き込み（BT.601 用の値も注記）。他コーデックは、推定で問題なければ対処不要、必要時のみ再エンコード | コーデック依存 |
| range_tag | 色レンジが不明 | h264/hevc は `video_full_range_flag=0` を bsf で書き込み。他は再エンコード案 | コーデック依存 |
| vfr | VFR / PTS の大きなギャップ | remux では直らない旨と、`-fps_mode cfr` での再エンコード案（まず無加工で試す推奨を明記） | 再エンコード |
| interlace | インターレース | `-vf bwdif` でデインターレースして再エンコード | 再エンコード |
| reencode_broken | ビットストリーム破損 | `-err_detect ignore_err` で読み飛ばして再エンコード（元データの再入手を推奨と明記） | 再エンコード |

同じ修復キーの問題が複数あっても、コマンドは 1 回だけ提示します（重複排除）。`-Target` で対象外としたツール固有の問題については、対処を表示しません。

### 出力先が常に `.mkv` である理由

修復コマンドの出力（および後述の `-FixScript` が書き出す ffmpeg コマンド）は、入力の拡張子にかかわらず常に `.mkv`（Matroska）にしています。入力と同じ拡張子では修復にならない／失敗するケースがあるためです。

- **拡張子非対応そのものが修復対象**: 拡張子が lada-ex 対応外（例: `.flv`）のとき、同じ拡張子で出すと非対応のままになります。`.mkv` は lada-ex / jasna 両対応です。
- **mkv が最も寛容**: 負 PTS・PTS 欠落・特殊な time_base などを `+genpts` / `-avoid_negative_ts make_zero` で作り直したストリームを mp4 に戻すと制約に引っかかり再発・失敗しやすい一方、mkv は素直に格納できます。
- **コーデックを選ばない**: `.avi` / `.wmv` / `.vob` などへ HEVC を正規に格納できないコンテナでも、mkv なら確実に収まります。

なお、`-map 0` で全ストリームをコピーする修復コマンドには `-map -0:d` を併用し、データストリーム（例: mp4 の `bin_data` チャプターテキスト）を除外しています。Matroska は audio/video/subtitle のみ格納可能で、データストリームを含めると `Only audio, video, and subtitles are supported for Matroska` でヘッダ生成に失敗するためです。`-map -0:d` はデータストリームが無いファイルでは無害です。

---

## 既知の制限

- standard の全パケットスキャンはデコードを行わないため、画質の破損（ビットストリーム破損）は検出できません。検出したい場合は full レベルを使ってください。
- VR 素材（VR180/VR360/TAB）の解像度・アスペクト比の妥当性は検査しません（lada-ex 側にも検証ロジックがないためです）。
- 音声は、コーデック名の表示に加え、`standard` 以上で「PTS と DTS の両方が無いパケット」の有無のみを検査します（jasna が該当パケットを破棄するためです）。コンテナ非互換の音声は jasna が自動で AAC に再エンコードするため、事前チェックは不要です。
- 判定基準は lada-ex / jasna の調査時点の仕様に基づいています。ツール側の仕様変更時は、スクリプト冒頭の定数（jasna はバージョン別の `$JasnaSpecs` テーブル）の見直しが必要です。
- `-JasnaVersion` が選べるのは調査済みの 0.7.2 / 0.8.1 のみです。他のバージョンを使う場合は、挙動が近い方を指定してください。

---

## 開発メモ（PowerShell 5.1 / 7 両対応の制約）

このツールに手を入れる方向けの注意点です。

- `Check-VideoInput.ps1` は **UTF-8（BOM 付き）** で保存してください。BOM が無いと、PowerShell 5.1 が CP932 として誤読し、日本語リテラルが壊れます。
- `Check-VideoInput.bat` は **ASCII のみ** で記述してください。cmd は bat を OEM コードページで読むため、UTF-8 の日本語コメントを書くとパーサが壊れます。
- ffprobe / ffmpeg の呼び出しは、「関数ローカルで `$ErrorActionPreference = "Continue"` に切り替え、`2>&1` で ErrorRecord を回収する」というパターンを維持してください。PowerShell 5.1 は `Stop` のまま native コマンドの stderr をリダイレクトすると、NativeCommandError で停止してしまいます。

---

## ライセンス

[MIT License](LICENSE) で公開しています。

判定基準の参照元（いずれも公開プロジェクトです）:

- lada-ex: <https://codeberg.org/comman/lada-ex>
- jasna: <https://github.com/Kruk2/jasna>
