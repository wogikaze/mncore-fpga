# board_test（WP04）

`brd_host_if`（UART のホストプロトコル）に、BSRAM の試験用メモリと RUN スタブをつないだデザイン。
プロトコルは [`mncore/rtl/board/PROTOCOL.md`](../../rtl/board/PROTOCOL.md)。

| 空間 | 中身 |
| --- | --- |
| 0x00 `IMEM` | 64 エントリ × 8 レーン = 512 長語（全語の書き込みだけ） |
| 0x0F `TEST` | 8192 長語 = 64 KiB（バイトマスク可） |

`RUN(start, count)` はスタブが 1 クロックに 1 エントリ進めるだけで、命令は実行しない。
`start + count` が 64 を超えると `E_RANGE`（info = 64）で止まる。

## ビルドと書き込み

```powershell
.\mncore\fpga\board_test\build.ps1            # build\board_test.fs を作る（初期 1 Mbaud）
.\mncore\fpga\board_test\build.ps1 -Program   # SRAM に書き込む（Flash には書かない）
```

実機を使う前に `C:\wgkz\nano20k\mncore\.board.lock` を取ること（契約 §9）。

## 試験

```powershell
$py = "C:\wgkz\nano20k\.venv\Scripts\python.exe"
& $py mncore\tools\host\hwtest.py               # WP04 の受入試験一式（PASS / FAIL）
& $py mncore\tools\host\mnhost.py bench         # 1/2/3 Mbaud で 64 KiB の書き込み・読み出し・照合と速度
```

## LED（負論理）

| LED | 意味 |
| --- | --- |
| 0 | 生存表示（約 0.8 Hz） |
| 1 | UART 受信 |
| 2 | UART 送信 |
| 3 | 誤り（CRC、フレーミング、あふれ、タイムアウト） |
| 4 | `SET_BAUD` の仮採用中 |
| 5 | RUN スタブが実行中 |

S1 ボタン（ピン 88）でデザイン全体をリセットする（ボーレートも初期値に戻る）。

## ピン

`uart_tx` = 69（FPGA → BL616）、`uart_rx` = 70（BL616 → FPGA）、`clk` = 4（27 MHz）、`btn_rst` = 88、LED = 15〜20。
UART の出典は Sipeed 公式の例 [TangNano-20K-example `uart/src/top.cst`](https://github.com/sipeed/TangNano-20K-example/blob/d8e3cfb86ac19966244cc99d12c1da84d7ba4199/uart/src/top.cst)。
