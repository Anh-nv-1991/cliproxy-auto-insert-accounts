# Restores the locally patched management panel (with the Plus-only filter)
# into the running cliproxyapi-standalone container after a container recreate.
#
# The patched file lives here because the rendered panel asset is NOT mounted
# into the container (config.yaml, static/ and auths/ are bind-mounted instead),
# and upstream panel releases would otherwise overwrite the local edit.
#
# Prereqs (already in repo config.yaml):
#   remote-management.disable-auto-update-panel: true
#
# Usage:  .\ops\panel-plus-patch\restore.ps1 [-ContainerName cliproxyapi-standalone]

param(
    [string]$ContainerName = "cliproxyapi-standalone"
)

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$patched   = Join-Path $scriptDir "management.html"

if (-not (Test-Path $patched)) {
    throw "patched panel not found: $patched"
}

# Prereq check: panel auto-update must be disabled or the 3-hourly updater
# will detect the digest mismatch and overwrite the local patch.
if (docker inspect $ContainerName 2>$null) {
    $configOk = docker exec $ContainerName sh -c "grep -q 'disable-auto-update-panel: true' /CLIProxyAPI/config.yaml"
    if (-not $configOk) {
        Write-Warning "disable-auto-update-panel is not true in the container config - the patch may be overwritten by the panel auto-updater."
    }
}

docker cp $patched "${ContainerName}:/CLIProxyAPI/static/management.html"

$size = docker exec $ContainerName sh -c "wc -c < /CLIProxyAPI/static/management.html"
Write-Output "panel restored: $ContainerName:/CLIProxyAPI/static/management.html ($size bytes)"
Write-Output "Hard refresh the browser (Ctrl+F5) to pick up the new panel."
