@echo off
rem 使い方:  build.bat        -> ビルドしてSRAMに書き込み
rem          build.bat flash  -> ビルドしてFlashに書き込み
cd /d %~dp0
cls

yosys -p "read_verilog top.v; synth_gowin -json synth.json -family gw2a" || goto :err
nextpnr-himbaechel --json synth.json --write pnr.json --device GW2AR-LV18QN88C8/I7 --vopt family=GW2A-18C --vopt cst=tangnano20k.cst || goto :err
gowin_pack -c -d GW2A-18C -o top.fs pnr.json || goto :err

if /i "%1"=="flash" (
  openFPGALoader -b tangnano20k -f top.fs || goto :err
) else (
  openFPGALoader -b tangnano20k top.fs || goto :err
)
echo.
echo === OK ===
exit /b 0

:err
echo.
echo === FAILED ===
exit /b 1
