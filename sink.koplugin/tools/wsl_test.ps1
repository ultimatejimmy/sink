param (
    [switch]$Watch
)

# Ensure WSL passes software rendering and X11 driver flags
$env:LIBGL_ALWAYS_SOFTWARE = "1"
$env:SDL_VIDEO_DRIVER = "x11"
$env:SDL_VIDEODRIVER = "x11"

$EnvList = @("LIBGL_ALWAYS_SOFTWARE/u", "SDL_VIDEO_DRIVER/u", "SDL_VIDEODRIVER/u")
foreach ($item in $EnvList) {
    $varName = $item.Split('/')[0]
    if ($env:WSLENV) {
        if ($env:WSLENV -notlike "*$varName*") {
            $env:WSLENV = "$env:WSLENV:$item"
        }
    }
    else {
        $env:WSLENV = $item
    }
}

$WslHome = (wsl sh -c "echo -n ~").Trim()
$WSLDest = "$WslHome/.config/koreader/plugins/sink.koplugin"
$AppDir = "/usr/lib/koreader"
Write-Host "Using KOReader installation path: $AppDir" -ForegroundColor Yellow

# Locate plugin source directory
$PluginPath = $null
$Candidates = @(
    "$PSScriptRoot/..",
    "$PSScriptRoot/../sink.koplugin",
    "$PSScriptRoot/../../sink/sink.koplugin",
    "./sink/sink.koplugin",
    "./sink.koplugin",
    "."
)
foreach ($c in $Candidates) {
    if (Test-Path "$c/_meta.lua") {
        $PluginPath = (Get-Item $c).FullName
        break
    }
}

if (-not $PluginPath) {
    Write-Host "Error: Could not locate sink.koplugin source directory with _meta.lua." -ForegroundColor Red
    exit 1
}

Write-Host "Detected Plugin Source: $PluginPath" -ForegroundColor Gray

function Run-Workflow {
    Write-Host "`n--- Starting Verification Workflow for Sink ---" -ForegroundColor Cyan
    
    # 1. Sync to WSL
    Write-Host "Syncing to WSL..." -NoNewline
    $WslSrc = (wsl wslpath -a -u "$PluginPath").Trim()
    
    wsl bash -c "mkdir -p '$WslHome/.config/koreader/plugins'"
    wsl bash -c "rsync -rv --delete --exclude='.git' --exclude='*.log' '$WslSrc/' '$WSLDest/'"
    if ($LASTEXITCODE -ne 0) {
        Write-Host " FAILED" -ForegroundColor Red
        return $false
    }
    Write-Host " SUCCESS" -ForegroundColor Green

    # 2. Unit Tests
    Write-Host "Running unit tests (Bundled LuaJIT in WSL)..."
    
    # Test 1: _meta.lua verification
    Write-Host "Running _meta.lua verification test..."
    $MetaTestCmd = "cd $AppDir && LUA_PATH='$WSLDest/?.lua;./?.lua;./?/init.lua;frontend/?.lua;frontend/?/init.lua;libs/?.lua;common/?.lua;common/?/init.lua;;' LUA_CPATH='libs/libkoreader-?.so;libs/?.so;./?.so;;' ./luajit $WSLDest/tests/sink_meta_test.lua"
    wsl bash -c "$MetaTestCmd"
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Meta Tests FAILED." -ForegroundColor Red
        return $false
    }

    # Test 2: main.lua module verification
    Write-Host "Running main.lua plugin logic tests..."
    $ModuleTestCmd = "cd $AppDir && LUA_PATH='$WSLDest/?.lua;./?.lua;./?/init.lua;frontend/?.lua;frontend/?/init.lua;libs/?.lua;common/?.lua;common/?/init.lua;;' LUA_CPATH='libs/libkoreader-?.so;libs/?.so;./?.so;;' ./luajit $WSLDest/tests/sink_module_test.lua"
    wsl bash -c "$ModuleTestCmd"
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Plugin Module Tests FAILED." -ForegroundColor Red
        return $false
    }

    Write-Host "All Tests PASSED" -ForegroundColor Green

    # 3. Restart KOReader in background
    Write-Host "Restarting KOReader..." -ForegroundColor Cyan
    wsl bash -c "pkill -9 -f koreader || true"
    Start-Sleep -Milliseconds 500

    Write-Host "Starting KOReader in WSL..."
    wsl bash -c "nohup dbus-launch --exit-with-session /usr/bin/koreader >/dev/null 2>&1 &"

    Write-Host "`nReady!" -ForegroundColor Green
    return $true
}

if ($Watch) {
    Write-Host "Watching for changes in $PluginPath..." -ForegroundColor Magenta
    $watcher = New-Object System.IO.FileSystemWatcher
    $watcher.Path = $PluginPath
    $watcher.Filter = "*.lua"
    $watcher.IncludeSubdirectories = $true
    $watcher.EnableRaisingEvents = $true

    $action = {
        Run-Workflow
    }

    Register-ObjectEvent $watcher "Changed" -Action $action
    Register-ObjectEvent $watcher "Created" -Action $action
    Register-ObjectEvent $watcher "Deleted" -Action $action
    Register-ObjectEvent $watcher "Renamed" -Action $action

    while ($true) { Start-Sleep -Seconds 1 }
}
else {
    Run-Workflow
}
