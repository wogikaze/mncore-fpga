# mncore-fpga

Executing **MN-Core 2** machine code (the flat `j`/`m` words emitted by the official `assemble3`) on a **Sipeed Tang Nano 20K** (Gowin GW2AR-18), on a reduced topology, bit-compatible with the official emulator.

MN-Core 2 を縮小トポロジで Tang Nano 20K 上に実装し、公式アセンブラが出力した機械語をそのまま実行する試みです。

- Plan & design notes (Japanese): [`mncore/README.md`](mncore/README.md)
- Schedule / work packages: [`mncore/05-schedule.md`](mncore/05-schedule.md), [`mncore/wp/`](mncore/wp/)
- Machine-code field notes: <https://scrapbox.io/mncore/機械語>
- Reference simulator & SDM text: [wogikaze/mncore](https://github.com/wogikaze/mncore) (submodule `third_party/mncore`)

The official assembler/emulator binaries are **not** included; obtain them from the MN-Core Challenge distribution.

License: MIT
