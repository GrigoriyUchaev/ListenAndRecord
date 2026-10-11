# Builds whisper.cpp for Windows x64 and copies whisper-cli.exe + DLLs into the app.
# GGML_CPU_ALL_VARIANTS: one build that picks the best code for the CPU at runtime —
# SSE4.2 on old processors (e.g. Core i5-760), AVX2 on modern ones (e.g. Ryzen 5 5600H).
# Static MSVC runtime and no OpenMP: no Visual C++ Redistributable needed. Works on Windows 10 and 11.
param(
    [string]$Version = "v1.9.2",
    [string]$Out = "windows/ListenAndRecord/whisper"
)
$ErrorActionPreference = "Stop"
$src = "build/whisper.cpp-$Version"
if (-not (Test-Path $src)) {
    git clone --depth 1 --branch $Version https://github.com/ggml-org/whisper.cpp $src
}
cmake -S $src -B "$src/build" -G "Visual Studio 17 2022" -A x64 `
    -DBUILD_SHARED_LIBS=ON `
    -DGGML_NATIVE=OFF `
    -DGGML_BACKEND_DL=ON `
    -DGGML_CPU_ALL_VARIANTS=ON `
    -DGGML_OPENMP=OFF `
    -DWHISPER_BUILD_TESTS=OFF `
    -DWHISPER_BUILD_EXAMPLES=ON `
    -DWHISPER_BUILD_SERVER=OFF `
    -DWHISPER_SDL2=OFF `
    -DCMAKE_POLICY_DEFAULT_CMP0091=NEW `
    -DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded
if ($LASTEXITCODE -ne 0) { throw "cmake configure failed" }
cmake --build "$src/build" --config Release -j 4
if ($LASTEXITCODE -ne 0) { throw "cmake build failed" }

New-Item -ItemType Directory -Force $Out | Out-Null
$bin = "$src/build/bin/Release"
Copy-Item "$bin/whisper-cli.exe" $Out -Force
Get-ChildItem -Path "$src/build" -Recurse -Filter *.dll |
    Where-Object { $_.FullName -match "\\Release\\" } |
    ForEach-Object { Copy-Item $_.FullName $Out -Force }
Get-ChildItem $Out | Format-Table Name, Length
