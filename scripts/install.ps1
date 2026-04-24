[CmdletBinding()]
param(
    [string]$Dir = $(if ($env:WASMZ_INSTALL_DIR) { $env:WASMZ_INSTALL_DIR } else { Join-Path $env:LOCALAPPDATA "wasmz\bin" }),
    [string]$Tag = $(if ($env:WASMZ_VERSION) { $env:WASMZ_VERSION } else { "latest" }),
    [string]$Repo = $(if ($env:WASMZ_REPO) { $env:WASMZ_REPO } else { "Ray-D-Song/wasmz" }),
    [switch]$SkipPathUpdate
)

$ErrorActionPreference = "Stop"

function Write-Info {
    param([string]$Message)
    Write-Host "» $Message"
}

function Fail {
    param([string]$Message)
    throw $Message
}

function Get-AuthHeaders {
    $headers = @{
        Accept = "application/vnd.github+json"
        "X-GitHub-Api-Version" = "2022-11-28"
    }

    if ($env:GH_TOKEN) {
        $headers["Authorization"] = "Bearer $($env:GH_TOKEN)"
    } elseif ($env:GITHUB_TOKEN) {
        $headers["Authorization"] = "Bearer $($env:GITHUB_TOKEN)"
    }

    return $headers
}

function Get-PlatformSuffix {
    $isWindowsHost = ($env:OS -eq "Windows_NT") -or ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT)
    if (-not $isWindowsHost) {
        Fail "install.ps1 is intended for Windows. Use install.sh on Linux or macOS."
    }

    $arch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant()
    switch ($arch) {
        "x64" { return "windows-x86_64" }
        "arm64" { return "windows-arm64" }
        default { Fail "Unsupported Windows architecture: $arch" }
    }
}

function Resolve-ReleaseTag {
    param(
        [string]$Repository,
        [string]$RequestedTag
    )

    if ($RequestedTag -ne "latest") {
        return $RequestedTag
    }

    $apiUrl = "https://api.github.com/repos/$Repository/releases/latest"
    try {
        $release = Invoke-RestMethod -Uri $apiUrl -Headers (Get-AuthHeaders)
    } catch {
        Fail "Unable to fetch latest release from $Repository. Make sure at least one GitHub release has been published."
    }

    if (-not $release.tag_name) {
        Fail "Failed to parse latest release tag from GitHub API response."
    }

    return [string]$release.tag_name
}

function Ensure-UserPathContains {
    param([string]$InstallDir)

    $currentUserPath = [Environment]::GetEnvironmentVariable("Path", "User")
    $entries = @()
    if ($currentUserPath) {
        $entries = $currentUserPath.Split(';', [System.StringSplitOptions]::RemoveEmptyEntries)
    }

    foreach ($entry in $entries) {
        if ($entry.TrimEnd('\') -ieq $InstallDir.TrimEnd('\')) {
            return
        }
    }

    $newUserPath = if ($currentUserPath) {
        "$currentUserPath;$InstallDir"
    } else {
        $InstallDir
    }

    [Environment]::SetEnvironmentVariable("Path", $newUserPath, "User")
    Write-Warning "$InstallDir has been added to your user PATH. Open a new terminal for it to take effect."
}

function Install-Wasmz {
    $platformSuffix = Get-PlatformSuffix
    $tagName = Resolve-ReleaseTag -Repository $Repo -RequestedTag $Tag
    $archiveName = "wasmz-$tagName-$platformSuffix.zip"
    $downloadUrl = "https://github.com/$Repo/releases/download/$tagName/$archiveName"

    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("wasmz-install-" + [System.Guid]::NewGuid().ToString("N"))
    $archivePath = Join-Path $tempRoot $archiveName
    $extractDir = Join-Path $tempRoot "extract"
    $binaryName = "wasmz.exe"
    $targetPath = Join-Path $Dir $binaryName
    $tempTarget = "$targetPath.tmp"

    try {
        New-Item -ItemType Directory -Force -Path $tempRoot, $extractDir, $Dir | Out-Null

        Write-Info "Resolved release tag: $tagName"
        Write-Info "Detected platform: $platformSuffix"
        Write-Info "Downloading $downloadUrl"

        try {
            Invoke-WebRequest -Uri $downloadUrl -OutFile $archivePath
        } catch {
            Fail "Failed to download $archiveName. The release may not contain an artifact for $platformSuffix."
        }

        Expand-Archive -Path $archivePath -DestinationPath $extractDir -Force

        $sourcePath = Join-Path $extractDir $binaryName
        if (-not (Test-Path -LiteralPath $sourcePath)) {
            Fail "Downloaded archive did not contain $binaryName"
        }

        Copy-Item -LiteralPath $sourcePath -Destination $tempTarget -Force
        Move-Item -LiteralPath $tempTarget -Destination $targetPath -Force

        Write-Info "Installed $binaryName to $targetPath"

        if (-not $SkipPathUpdate) {
            Ensure-UserPathContains -InstallDir $Dir
        }
    } finally {
        if (Test-Path -LiteralPath $tempRoot) {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force
        }
    }
}

Install-Wasmz
