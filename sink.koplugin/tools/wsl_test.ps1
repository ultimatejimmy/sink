param (
    [switch]$Watch
)

# Ensure WSL passes software rendering and X11 driver flags to fix graphics crashes & black screen issues in Copy Mode
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
$PluginDir = "sink.koplugin"
$WSLDest = "$WslHome/.config/koreader/plugins/sink.koplugin"

# The .deb package installs system-wide, so the app directory is static
$AppDir = "/usr/lib/koreader"
Write-Host "Using KOReader installation path: $AppDir" -ForegroundColor Yellow

function Run-Workflow {
    Write-Host "`n--- Starting Verification Workflow for Sink ---" -ForegroundColor Cyan
    
    # 1. Sync
    Write-Host "Syncing to WSL..." -NoNewline
    wsl mkdir -p (Split-Path $WSLDest -Parent)
    
    # Identify source directory
    $SrcDir = if (Test-Path "./sink.koplugin") { "./sink.koplugin/" } elseif (Test-Path "./_meta.lua") { "./" } else { "../sink.koplugin/" }
    
    wsl rsync -rv --delete --exclude=".git" --exclude="*.log" "$SrcDir" "$WSLDest/"
    if ($LASTEXITCODE -ne 0) {
        Write-Host " FAILED" -ForegroundColor Red
        return $false
    }
    Write-Host " SUCCESS" -ForegroundColor Green

    # 2. Unit Tests
    Write-Host "Running unit tests (Bundled LuaJIT in WSL)..."
    
    # Test 1: _meta.lua verification
    Write-Host "Running _meta.lua verification test..."
    $MetaTestCmd = "cd $AppDir && LUA_PATH='{0}/?.lua;./?.lua;./?/init.lua;frontend/?.lua;frontend/?/init.lua;libs/?.lua;common/?.lua;common/?/init.lua;;' LUA_CPATH='libs/libkoreader-?.so;libs/?.so;./?.so;;' ./luajit {0}/tests/sink_meta_test.lua" -f $WSLDest
    wsl bash -c `"$MetaTestCmd`"
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Meta Tests FAILED." -ForegroundColor Red
        return $false
    }

    # Test 2: main.lua module verification
    Write-Host "Running main.lua plugin logic tests..."
    $ModuleTestCmd = "cd $AppDir && LUA_PATH='{0}/?.lua;./?.lua;./?/init.lua;frontend/?.lua;frontend/?/init.lua;libs/?.lua;common/?.lua;common/?/init.lua;;' LUA_CPATH='libs/libkoreader-?.so;libs/?.so;./?.so;;' ./luajit {0}/tests/sink_module_test.lua" -f $WSLDest
    wsl bash -c `"$ModuleTestCmd`"
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Plugin Module Tests FAILED." -ForegroundColor Red
        return $false
    }

    Write-Host "All Tests PASSED" -ForegroundColor Green

    # 3. Restart KOReader
    Write-Host "Restarting KOReader..." -ForegroundColor Cyan
    wsl pkill -9 -f koreader 2>$null
    Start-Sleep -Seconds 1

    # Define start command
    $DefaultCmd = "C:\Windows\System32\wsl.exe --exec dbus-launch --exit-with-session bash -c `"/usr/bin/koreader`""
    $StartCmd = if ($env:KOREADER_START_CMD) { $env:KOREADER_START_CMD } else { $DefaultCmd }
    
    Write-Host "Starting KOReader: $StartCmd"
    # Use cmd /c start to ensure it's fully detached and quotes are preserved
    $cmdLine = "/c start `"`" $StartCmd"
    Start-Process cmd.exe -ArgumentList $cmdLine -WindowStyle Hidden

    Write-Host "`nReady!" -ForegroundColor Green
    return $true
}

if ($Watch) {
    Write-Host "Watching for changes..." -ForegroundColor Magenta
    $watcher = New-Object System.IO.FileSystemWatcher
    $watcher.Path = (Get-Item ".").FullName
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
