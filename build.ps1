<#
  Builds the calculator.   Requires gcc/as/ld on PATH (MSYS2 UCRT64 or any MinGW-w64).

    .\build.ps1          # -> build\calculator.exe
    .\build.ps1 -Test    # also runs the engine test-suite (needs Python 3)
#>
param([switch]$Test)
$ErrorActionPreference = "Stop"
New-Item -ItemType Directory -Force build | Out-Null
gcc src/gui.s src/engine.s -o build/calculator.exe `
    -nostdlib -mwindows '-Wl,-e,Start' '-Wl,--gc-sections' `
    -luser32 -lgdi32 -lkernel32 -ldwmapi -s
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
"built build\calculator.exe ({0:N0} bytes)" -f (Get-Item build/calculator.exe).Length
if ($Test) { python tests/test_engine.py; exit $LASTEXITCODE }
