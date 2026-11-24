# Build the board test bitstream (and optionally load it into SRAM).
#
#   .\build.ps1                    # synth + place&route + pack -> build\board_test.fs
#   .\build.ps1 -Baud 3000000      # different reset baud rate (the host can also change it at run time)
#   .\build.ps1 -Program           # ... and load it into the FPGA SRAM (volatile; Flash is never written)
#
# Logs: build\yosys.log, build\nextpnr.log.  Utilisation and Fmax are printed at the end.
param(
    [int]$Baud = 1000000,
    [switch]$Program
)
$ErrorActionPreference = "Stop"

# OSS CAD Suite may be missing from the PATH of shells started before it was installed.
if (-not (Get-Command yosys -ErrorAction SilentlyContinue)) {
    $oss = Join-Path $env:LOCALAPPDATA "Programs\oss-cad-suite"
    $env:PATH = "$oss\bin;$oss\lib;$env:PATH"
}

$here  = $PSScriptRoot
$root  = Resolve-Path (Join-Path $here "..\..\..")
$build = Join-Path $here "build"
New-Item -ItemType Directory -Force $build | Out-Null

$rtl = @(
    "mncore/rtl/board/brd_ram_1r1w.v",
    "mncore/rtl/board/brd_fifo.v",
    "mncore/rtl/board/brd_uart_rx.v",
    "mncore/rtl/board/brd_uart_tx.v",
    "mncore/rtl/board/brd_host_if.v",
    "mncore/fpga/board_test/brd_test_mem.v",
    "mncore/fpga/board_test/brd_run_stub.v",
    "mncore/fpga/board_test/brd_board_test.v"
) | ForEach-Object { (Join-Path $root $_) -replace '\\', '/' }

$synth  = (Join-Path $build "synth.json") -replace '\\', '/'
$pnr    = (Join-Path $build "pnr.json") -replace '\\', '/'
$fs     = Join-Path $build "board_test.fs"
$cst    = Join-Path $here "board_test.cst"
$ylog   = Join-Path $build "yosys.log"
$nlog   = Join-Path $build "nextpnr.log"

function Invoke-Step([string]$name, [scriptblock]$cmd) {
    Write-Host "== $name"
    & $cmd
    if ($LASTEXITCODE -ne 0) { throw "$name failed (exit $LASTEXITCODE)" }
}

$reads = ($rtl | ForEach-Object { "read_verilog $_;" }) -join " "
$ys = "$reads chparam -set BAUD $Baud brd_board_test; synth_gowin -family gw2a -top brd_board_test -json $synth; stat"
Invoke-Step "yosys" { yosys -q -l $ylog -p $ys }

Invoke-Step "nextpnr" {
    nextpnr-himbaechel --json $synth --write $pnr --device GW2AR-LV18QN88C8/I7 `
        --vopt family=GW2A-18C --vopt cst=$cst --freq 27 -l $nlog 2>&1 | Out-Null
}
Invoke-Step "gowin_pack" { gowin_pack -c -d GW2A-18C -o $fs $pnr }

Write-Host "== utilisation (nextpnr)"
Select-String -Path $nlog -Pattern "Device utilisation" -Context 0, 40 |
    ForEach-Object { $_.Context.PostContext } |
    Where-Object { $_ -match "\d+/\s*\d+" -and $_ -notmatch "\s0/" } |
    ForEach-Object { Write-Host "  $($_.Trim())" }
Select-String -Path $nlog -Pattern "Max frequency for clock" | Select-Object -Last 1 |
    ForEach-Object { Write-Host "  $($_.Line.Trim())" }

if ($Program) {
    Invoke-Step "openFPGALoader (SRAM)" { openFPGALoader -b tangnano20k $fs }
}
Write-Host "OK: $fs"
