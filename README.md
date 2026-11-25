# mncore-fpga

Runs **MN-Core 2** machine code on a **Sipeed Tang Nano 20K** (Gowin GW2AR-LV18). The input is the flat machine code that the official assembler `assemble3` emits: 426-bit `j` words for the PEs and 82-bit `m` words for the MV unit. The FPGA runs a reduced topology of the chip, and the results are compared with the official emulator `gpfn3_package_main`.

日本語版: [docs/ja/README.md](docs/ja/README.md)

This is an unofficial project. The official assembler and emulator are not included (see [Requirements](#requirements)).

## What it does and what it does not

- The host PC sends the `assemble3 --instruction-mode flat --disable-packer` output over UART. The FPGA keeps the words in its instruction memory and executes them. `d set` / `d get` / `r` lines become memory writes and reads on the host side.
- The whole chip does not fit. MN-Core 2 has 4096 PEs and about 144 MiB of PE-local memory alone ([`mncore/01-target-analysis.md`](mncore/01-target-analysis.md)). The FPGA implements this reduced topology (chip figures from the same file; FPGA figures from [WP-37](mncore/status/WP-37.md) and [WP-33](mncore/status/WP-33.md)):

  | | MN-Core 2 | This FPGA (M2) |
  | --- | --- | --- |
  | Groups / L2B / L1B / MAB / PE | 4 / 8 / 64 / 1024 / 4096 | 1 / 1 / 1 / 1 / 4 (the 4 PEs share one datapath, time-multiplexed) |
  | LM0 / LM1 per PE | 2048 long words | 256 long words |
  | GRF0 / GRF1 per PE, T | 256 long words, 8 | same |
  | L1BM / L2BM | 8192 / 32768 long words | 1024 / 2048 long words |
  | PDM / DRAM (in the on-package SDRAM) | 4 MiB / 4 GiB per group | 1 MiB / 4 MiB, group 0 only |

  The implemented PEs are `n0c0b0m0p0`..`p3`. `$peid` and the other ID operands return the chip coordinates. An access beyond a reduced capacity stops the program with `E_RANGE`; the FPGA never wraps silently.
- Units that do not exist (the other 15 MABs, 7 L1Bs, ...) follow one of two rules, chosen when the bitstream is built:
  - **Zero rule** (default): transfers to a missing unit are dropped, and reduction or gather inputs from a missing unit are zero. The reference is the Rust simulator run on the same reduced topology.
  - **Replica rule** (`REPLICA=1`): a missing MAB / L1B is treated as a copy of the implemented one. For SPMD-like programs, where every unit holds the same data, the result equals the official 4096-PE run.
  - Programs whose data stays inside the implemented units give the official result under both rules.
- Not every unit fits in one bitstream (the practical limit is 75 % of the LUT4s, [WP-21](mncore/status/WP-21.md)). The design is built as **function-specific bitstreams**: for example, one with the vector MAU and one with L1BM + L2BM + MV. A program that needs both is run in parts, and the host copies the PE state from one bitstream to the next. This hand-over is manual today (`hello_hw.py`).
- Out of scope: the auto_stride (`i`) and packed formats. The double-precision matrix MAU (`dmfma` / `dmmul`) is not implemented. The rounding of half-precision extended-format matrix products is approximated (see [docs/divergences.md](docs/divergences.md)).

Design details: [docs/architecture.md](docs/architecture.md). ISA notes: [docs/isa-notes.md](docs/isa-notes.md). Differences between the official emulator and the Rust simulator: [docs/divergences.md](docs/divergences.md).

## Results

State at milestone **M2** (2026-11-25). **This section is the only place where the measured numbers are kept; the other documents link here.** Each row names the report in [`mncore/status/`](mncore/status/) that the numbers come from. Work in progress at the time of writing: a virtual PE (LM of 2048 long words, up to 64 PEs, WP34) and automatic switching between bitstreams (WP38).

How the results were compared:

- The official emulator always runs the whole chip (4096 PEs). The state of the implemented units is cut out of its dump and compared with the FPGA.
- "Match" means that every compared long word is identical. The compared state is the final state of the implemented PEs (the probe), plus L1BM, L2BM and DRAM in M2, plus the program's own `d get` output. The probe is 1,604 long words for 1 PE, 4,368 for 4 PEs and 15,632 for M2. PDM is not compared, because the official `d get $p` prints DRAM ([WP-02](mncore/status/WP-02.md)).
- Programs come from the `.vsm` corpus of the submodule `third_party/mncore` (959 files). Each set below contains the programs that the configuration can be compared on ([WP-02](mncore/status/WP-02.md), [WP-30](mncore/status/WP-30.md), [WP-37](mncore/status/WP-37.md)).
- "Value mismatch" counts programs that ran to the end and differ from the reference. The other non-matching programs stop at the same word with the same reason as the RTL simulation of the same configuration (`E_UNSUPPORTED` for a unit that is not in the bitstream, `E_RANGE` for a reduced capacity).

### On the board

| Bitstream (units) | Programs | Result | Same as RTL sim | Value mismatches | Source |
| --- | --- | --- | ---: | ---: | --- |
| **M1**: 1 PE, FP ALU subset `FPALU=3`, MAU | 260 (1-PE set) | 256 match the official emulator; 4 stop with `E_UNSUPPORTED` (floor ×2, fmax, bfn) | 260/260 | 0 | [WP-21](mncore/status/WP-21.md) |
| 1 PE, all PE units (`FPALU=1`, MAU), after the area work | 260 | 259 match; 1 needs 4 PEs (bfn) | 260/260 | 0 | [WP-35](mncore/status/WP-35.md) |
| 1 MAB (4 PEs), bitstream A: integer ALU + MAU | 260 (1-MAB set) | 242 match; 18 `E_UNSUPPORTED` (FP ALU ops, bfn) | 260/260 | 0 | [WP-30](mncore/status/WP-30.md) |
| 1 MAB, bitstream B: FP ALU `FPALU=3` + bfn, no MAU | 260 | 167 match; 93 `E_UNSUPPORTED` (MAU 92, fmax 1) | 260/260 | 0 | [WP-30](mncore/status/WP-30.md) |
| 1 MAB + matrix unit (no FP ALU, no vector MAU) | 122 matrix programs | 109 match; 13 `E_UNSUPPORTED` (vector MAU) | 122/122 | 0 | [WP-36](mncore/status/WP-36.md) |
| **M2a**: 1 MAB + L1BM + L2BM + MV (integer ALU only), zero rule | 247 (M2 set) | 79 match the official emulator (data stays inside the implemented units); 55 match the reduced-topology Rust simulator (zero rule); 31 `E_RANGE` at the same word as the Rust simulator; 82 `E_UNSUPPORTED` (MAU 73, FP ALU 9) | 247/247 | 0 | [WP-37](mncore/status/WP-37.md) |
| **M2a-R**: same units, replica rule | 247 | 85 match the official emulator (4096-PE cut); 31 `E_RANGE`; 82 `E_UNSUPPORTED`; 49 differ from the official run (programs whose units hold different data, so the replica does not reproduce them; the RTL simulation gives the same values) | 247/247 | n/a | [WP-37](mncore/status/WP-37.md) |

**hello_world** ([WP-37](mncore/status/WP-37.md)):

- The official problem (`problems/challenge/21.hello-world/main.vsm`) uses the vector MAU in words 0–3 and L1BM / L2BM / MV in words 4–8. It ran in two parts: bitstream A, then M2a or M2a-R, with the host copying the PE state (GRF, LM, T, OMR, `$mb` / `$nb`; 4,196 long words) in between.
  - Zero rule: all 15,632 compared long words match the reduced-topology Rust simulator. DRAM n0 does not hold "Hello, world!": the official result sums the same value over 16 MABs and 8 L1Bs.
  - Replica rule: DRAM n0 holds `48656c6c6f2c2077 6f726c64212afe00` ("Hello, world!"), and all 15,632 long words match the official emulator.
- A version that does not use the MAU (`mncompile/benchmarks/results/21.hello-world/kernel.vsm`, generated by the upstream compiler) runs on the single bitstream M2a. DRAM n0 words 0–1 hold "Hello, world!" even under the zero rule. All 15,632 long words match the Rust simulator (zero rule); on M2a-R they match the official emulator.

### RTL simulation (iverilog)

| Configuration | Programs | Result | Source |
| --- | --- | --- | --- |
| 1 PE, all PE units | 260 | 259 match the official emulator; 1 needs 4 PEs (bfn) | [WP-20](mncore/status/WP-20.md), [WP-37](mncore/status/WP-37.md) |
| 1 MAB (4 PEs) | 260 | 260 match | [WP-30](mncore/status/WP-30.md) |
| 1 MAB + matrix unit | 122 | 122 match | [WP-36](mncore/status/WP-36.md) |
| M2, all PE units, zero rule | 247 | 100 match the official emulator and the Rust simulator; 95 match the Rust simulator (zero rule); 52 `E_RANGE` (51 at the same word as the Rust simulator; 1 that the Rust parser cannot read); value mismatches 0 | [WP-37](mncore/status/WP-37.md) |
| M2, all PE units, replica rule | 247 | 117 match the official emulator (the 100 above and 17 SPMD-like programs, including the 4 hello_world variants) | [WP-37](mncore/status/WP-37.md) |

`E_RANGE` in the M2 set: 26 programs address LM beyond 256 long words (one is the FizzBuzz answer), 20 move more MV data than L2BM / PDM / DRAM hold, and 6 address L1BM beyond 1024 ([WP-37](mncore/status/WP-37.md)).

### Units and infrastructure

| Item | Result | Source |
| --- | --- | --- |
| ISA schema (`mncore/spec/isa/`) | 110 `j` fields and 12 `m` fields. Over 840 corpus programs (22,835 `j` and 727 `m` words), decode / encode round-trips with 0 mismatches against `assemble3 --print-csv` | [WP-01](mncore/status/WP-01.md) |
| Official emulator vs Rust simulator, whole corpus | 959 programs; 809 run on both; 801 identical. Of the 8 differences, 6 were an MV regression in the Rust simulator (fixed on the `topo-param` branch, after which all 146 problem checks agree) and 2 are the `d get $p` difference | [WP-02](mncore/status/WP-02.md), [WP-06](mncore/status/WP-06.md) |
| Unit test vectors | 584,743 rows. 34,685 rows where the Rust simulator differs (4 kinds) carry the official emulator's output as the expected value; every row is checked against the official emulator | [WP-03](mncore/status/WP-03.md) |
| Decoder (generated from the schema) | 8,926 `j` words and 1,220 `m` words, 0 mismatches | [WP-10](mncore/status/WP-10.md) |
| Integer ALU | 144,645 vector rows × 2 configurations | [WP-11](mncore/status/WP-11.md) |
| FMA and vector MAU | fp 62,340 rows, mau 52,480 rows, 39,669 boundary rows | [WP-12](mncore/status/WP-12.md) |
| FP ALU and block float | 151,856 rows | [WP-13](mncore/status/WP-13.md) |
| PE memories and masks | 86 programs, 29,568 long words, expected values from the official emulator | [WP-14](mncore/status/WP-14.md) |
| L1BM | 96 programs (64 PEs) and 49 programs (1 MAB); 186,396 reduction-network rows | [WP-31](mncore/status/WP-31.md) |
| L2BM | 105 programs | [WP-32](mncore/status/WP-32.md) |
| MV + SDRAM | 64 programs in simulation; on a test bitstream through SDRAM, 192 runs + 160 stress runs, all matching | [WP-33](mncore/status/WP-33.md) |
| Host link (UART through the BL616) | 22 hardware tests pass. Up to 3 Mbaud; reads from the FPGA are limited to about 70 KiB/s by the bridge | [WP-04](mncore/status/WP-04.md) |
| SDRAM controller | Whole 8 MiB × 100 passes without error at 54, 99 and 108 MHz; 99 MHz CL2: 387 MB/s sequential, 167 MB/s random | [WP-05](mncore/status/WP-05.md) |

### Resources and clocks

GW2AR-LV18 has 20,736 LUT4s and 46 BSRAM blocks. Designs above about 75 % LUT4 failed to place with nextpnr-himbaechel ([WP-21](mncore/status/WP-21.md)). The core runs at 27 MHz (the board oscillator); Fmax below is nextpnr's post-route estimate.

| Bitstream | LUT4 | BSRAM | Core Fmax | Source |
| --- | --- | --- | --- | --- |
| 1 PE, `FPALU=3` (M1) | 15,582 (75 %) | 23 | 48.07 MHz | [WP-21](mncore/status/WP-21.md) |
| 1 PE, all PE units | 14,703 (70.9 %) | 23 | 43.87 MHz | [WP-35](mncore/status/WP-35.md) |
| 1 MAB, A (integer ALU + MAU) | 15,552 (75 %) | 33 | 48.0 MHz | [WP-30](mncore/status/WP-30.md) |
| 1 MAB, A, rebuilt with the M2 RTL | 13,420 (65 %) | 31 | 41.99 MHz | [WP-37](mncore/status/WP-37.md) |
| 1 MAB, B (FP ALU + bfn) | 14,737 (71 %) | 33 | 49.4 MHz | [WP-30](mncore/status/WP-30.md) |
| 1 MAB + matrix unit | 14,956 (72 %) | 36 | 43.6 MHz | [WP-36](mncore/status/WP-36.md) |
| M2a (SDRAM at 54 MHz) | 14,928 (72 %) | 43 | 32.94 MHz | [WP-37](mncore/status/WP-37.md) |
| M2a-R (replica rule) | 15,493 (74.7 %) | 43 | 27.78 MHz | [WP-37](mncore/status/WP-37.md) |
| M2 with the vector MAU | does not fit: 19,825 LUT-equivalent in yosys (95.6 %) | 43 | — | [WP-37](mncore/status/WP-37.md) |

The M2 bitstreams run the SDRAM at 54 MHz because the SDRAM controller did not reach 99 MHz after place and route in the full design ([WP-37](mncore/status/WP-37.md)).

## Requirements

- **Board**: Sipeed Tang Nano 20K (GW2AR-LV18QN88C8/I7, family GW2A-18C) on USB. The UART goes through the on-board BL616 (FTDI-compatible, VID:PID 0403:6010).
- **FPGA tools**: [OSS CAD Suite](https://github.com/YosysHQ/oss-cad-suite-build) (yosys, nextpnr-himbaechel, gowin_pack, openFPGALoader, iverilog, verilator). Developed with the 2026-11-23 release on Windows 11.
- **Python**: developed with Python 3.13; packages in [`mncore/requirements.txt`](mncore/requirements.txt) (`pyyaml`, `pyserial`).
- **Rust** (`cargo`): builds the reference dumpers that link the Rust simulator (`mncore/golden_rs`, `mncore/sim/regress/topo_rs`) and the vector generator (`mncore/vecgen`).
- **Official tools**: `assemble3` and `gpfn3_package_main` (the 2024 distribution, judge v20240826). **They are not included in this repository.** Obtain them from the MN-Core Challenge distribution. The scripts call them inside WSL (Ubuntu) and expect them in `~/wgkz/mncore/judge/judge-py/mncore2_emuenv`; the golden tools accept `MNCORE_EMU_DIR_WSL` and `MNCORE_WSL_DISTRO` instead. They are needed to produce reference results and `.asm` input, not to build or load the bitstreams.
- **Submodule**: `third_party/mncore` ([wogikaze/mncore](https://github.com/wogikaze/mncore), branch `topo-param`) supplies the Rust simulator (`viz/core`), the SDM text (`docs/mncore_llm`) and the program corpus.

## Try it

From the repository root. The scripts are Python; there is no makefile.

```sh
git submodule update --init third_party/mncore
python -m pip install -r mncore/requirements.txt
```

**Simulation only** (no board, no official tools; the committed scripts carry the expected values):

```sh
python mncore/tools/simrun.py core   # 1 PE, 27 directed tests
python mncore/tools/simrun.py mab    # 1 MAB (4 PEs)
python mncore/tools/simrun.py m2     # M2 core with L1BM, L2BM, MV and a behavioural SDRAM
```

**Build and load a bitstream.** `--program` writes the FPGA SRAM only (volatile; the Flash is never written). One place-and-route run took about 20 to 60 minutes during development.

```sh
python mncore/fpga/top_m2/build.py --tag M2a --program                      # M2a, zero rule
python mncore/fpga/top_m2/build.py --tag M2aR --param REPLICA=1 --program   # M2a-R, replica rule
python mncore/fpga/top_mab/build.py --tag A                                  # 1 MAB with the MAU (bitstream A)
python mncore/tools/host/mnhost.py info                                      # design ID, topology, units
```

The output is `mncore/fpga/<design>/build/<tag>/<design>.fs`. `python mncore/fpga/top_m2/build.py --fs <file.fs>` loads an existing bitstream.

**Run programs on the board.** These need the official tools in WSL, because the reference results are made first:

```sh
# the M2 set: official emulator, reduced-topology Rust simulator and RTL simulation
python mncore/sim/regress/run.py --m2
# optional: the RTL simulation of the board's units (M2a), for the "same as RTL" column
python mncore/sim/regress/run.py --m2 --define TB_FPALU=0 --define TB_MAU=0 --define TB_BFN=0
# then the same programs on the board
python mncore/fpga/top_m2/hwrun.py --all --no-lock-check

# M1 (1-PE bitstream mncore/fpga/top_1pe)
python mncore/sim/regress/run.py
python mncore/fpga/top_1pe/hwrun.py --all --fpalu 3 --no-lock-check

# hello_world over two bitstreams, with the PE state handed over by the host
python mncore/fpga/top_m2/hello_hw.py --mau-fs mncore/fpga/top_mab/build/A/top_mab.fs \
    --m2-fs mncore/fpga/top_m2/build/M2aR/top_m2.fs --no-lock-check
```

`mnhost.py run X.asm -o X.ndmp` runs one `.asm` (the whole emulator input made by `mncore/tools/golden/run_official.py`) and writes the normalized dump. `mncore/tools/golden/ndiff.py` compares two dumps.

Notes:

- The hardware scripts check for a board lock file that was used during development (`C:\wgkz\nano20k\mncore\.board.lock`). Pass `--no-lock-check` outside that setup.
- Do not send Ctrl-X or Ctrl-C on their own to the COM port: the BL616 enters its shell and stops forwarding FPGA output. `python mncore/tools/host/mnhost.py bridge reboot` recovers it. That reboot reloads the FPGA from Flash, so load the bitstream again ([WP-04](mncore/status/WP-04.md), [`mncore/rtl/board/PROTOCOL.md`](mncore/rtl/board/PROTOCOL.md)).
- On Windows with `core.autocrlf=true`, the submodule's `.vsm` files are checked out with CRLF, which `assemble3` rejects. The scripts strip CR before calling it.

## Repository layout

| Path | Contents |
| --- | --- |
| `mncore/spec/isa/` | Field definitions of the `j` and `m` words (`j_flat.yaml`, `m.yaml`) and the open questions (`UNKNOWN.md`) |
| `mncore/rtl/` | Verilog-2005 RTL: `board` (UART, host protocol), `dec` (generated decoder), `alu`, `fpu`, `pe`, `mab`, `core`, `l1bm`, `l2bm`, `mv`, `sdram`, `top` |
| `mncore/fpga/` | Board designs (`top_1pe`, `top_mab`, `top_m2`), test designs, RAM / DSP recipes, place-and-route and hardware logs |
| `mncore/sim/` | Testbenches (`tb/<unit>/`), fixed test vectors, the corpus regression (`regress/`) |
| `mncore/tools/` | `simrun.py` (simulation, lint, synthesis), `mnisa` (Python decoder), `golden` (reference runs and dump comparison), `host/mnhost.py` (host tool) |
| `mncore/vecgen/`, `mncore/golden_rs/` | Rust: test vector generator and reference dumper (use the Rust simulator in the submodule) |
| `mncore/status/` | Reports of each work package (Japanese). The numbers above come from these |
| `mncore/*.md`, `mncore/wp/` | Plan, schedule, shared contract, work package briefs (Japanese) |
| `docs/` | This documentation (`docs/ja/`: Japanese) |

## License and acknowledgements

The code and documents in this repository are under the MIT License ([LICENSE](LICENSE)). The submodule `third_party/mncore` is a separate repository.

This work builds on:

- Preferred Networks: MN-Core 2, its Software Developer's Manual (SDM), and the official assembler and emulator from the MN-Core Challenge distribution. The emulator is the final reference for every result here. The binaries are not redistributed.
- [wogikaze/mncore](https://github.com/wogikaze/mncore): the Rust reference simulator (`viz/core`), the SDM text (`docs/mncore_llm`) and the program corpus.
- The Scrapbox notes [mncore/機械語](https://scrapbox.io/mncore/機械語): observed field layouts of the machine code.
- [nand2mario/sdram-tang-nano-20k](https://github.com/nand2mario/sdram-tang-nano-20k) (Apache-2.0): reference for the embedded SDRAM organization, port names and clock phase. No code was copied ([`mncore/rtl/sdram/README.md`](mncore/rtl/sdram/README.md)).
- [YosysHQ/apicula](https://github.com/YosysHQ/apicula) (MIT): SDRAM pin list and rPLL / IOB settings of the GW2AR-18. YosysHQ OSS CAD Suite: the whole FPGA flow.
- [sipeed/TangNano-20K-example](https://github.com/sipeed/TangNano-20K-example): UART pin assignment ([`mncore/fpga/board_test/README.md`](mncore/fpga/board_test/README.md)).
- Gowin datasheets and user guides (DS226, DS102, UG285, UG286, UG287) and the Sipeed Tang Nano 20K wiki: device resources ([`mncore/07-device-budget.md`](mncore/07-device-budget.md)).

## 日本語の要約

MN-Core 2 の公式アセンブラ `assemble3` が出力した flat 形式の機械語（`j` 426bit、`m` 82bit）を、Tang Nano 20K 上の縮小トポロジ（1 MAB = 4 PE を時分割、L1BM、L2BM、MV、SDRAM 上の PDM / DRAM）でそのまま実行し、公式エミュレータと比べる試みです。全ユニットは 1 本のビットストリームに載らないため、機能別のビットストリームを使います。M2（2026-11-25）の時点で、公式の hello_world を実機で実行し、複製規則では "Hello, world!" が出て公式と一致しました。数字は上の [Results](#results) にまとめています。公式のバイナリは同梱していません。詳しくは [docs/ja/README.md](docs/ja/README.md) を見てください。
