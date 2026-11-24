# FPGA ツールのインストール先

Windows x64 版の OSS CAD Suite を、この PC のユーザー領域に展開した。[公式リリース 2026-11-23](https://github.com/YosysHQ/oss-cad-suite-build/releases/tag/2026-11-23)

```text
C:\Users\Wogikaze\AppData\Local\Programs\oss-cad-suite
```

PowerShell では `$env:LOCALAPPDATA\Programs\oss-cad-suite` で参照できる。

| ツール | バージョン | インストール先からの相対パス |
| --- | --- | --- |
| Yosys | `0.71+77` | `bin\yosys.exe` |
| nextpnr-himbaechel | `0.11.1-121-g15b77f5f` | `bin\nextpnr-himbaechel.exe` |
| openFPGALoader | `1.2.0` | `bin\openFPGALoader.exe` |
| gowin_pack | OSS CAD Suite 同梱 | `bin\gowin_pack.exe` |

ユーザーの `PATH` に `oss-cad-suite\bin` と `oss-cad-suite\lib` を登録済み。新しい PowerShell から各コマンドを直接実行できる。`OPENFPGALOADER_SOJ_DIR` はインストール先の `share\openFPGALoader` を指している。

USB ドライバーの設定に使った Zadig 2.9 の実行ファイルは `%LOCALAPPDATA%\Programs\Zadig\zadig-2.9.exe` にある。
