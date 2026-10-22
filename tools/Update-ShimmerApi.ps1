<#
.SYNOPSIS
Moves the LabVIEW wrapper to a ShimmerAPI release from nuget.org, rebuilds it and refreshes
ShimmerLabview/Bin/. With -Check, changes nothing and checks that Bin/ is complete.

.DESCRIPTION
The wrapper pins ShimmerAPI in three places: packages.config, and the reference's version and
HintPath in ShimmerLVWrapper.csproj.

  (default)  Moves the pin to the newest stable ShimmerAPI on nuget.org, if that is newer, or to
             -Version. Rebuilds the wrapper and copies the DLLs it needs into ShimmerLabview/Bin/.
             -Version set to the pinned version rebuilds and refreshes Bin/ without moving the pin.
  -Check     Builds the wrapper and checks that ShimmerLabview/Bin/ holds every DLL the wrapper
             needs, with ShimmerAPI.dll at the pinned version. Changes nothing in the repo.

The DLLs the wrapper needs come from the build, not from a list: ShimmerLVWrapper.dll's references,
followed through every DLL the build put next to it. What the .NET Framework supplies (mscorlib,
netstandard, System, ...) stays out of Bin/. Nothing is deleted from Bin/.

.github/workflows/update-shimmerapi.yml runs this, and it runs the same way by hand. It needs
Windows PowerShell 5.1, which can load an assembly to read its references without running it, and
MSBuild from Visual Studio or the Build Tools.

When it moves the pin, it writes from=<old> and to=<new> to GITHUB_OUTPUT, if set, for the workflow.

.EXAMPLE
.\tools\Update-ShimmerApi.ps1 -Check

.EXAMPLE
.\tools\Update-ShimmerApi.ps1 -Version 1.4.0
#>
#Requires -PSEdition Desktop
[CmdletBinding()]
param(
    # The ShimmerAPI version to move to. Blank: the newest stable one on nuget.org, if newer.
    [string]$Version,
    [switch]$Check
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$wrapper = Join-Path $repo 'ShimmerLabviewC#Wrapper'
$packagesConfig = Join-Path $wrapper 'packages.config'
$project = Join-Path $wrapper 'ShimmerLVWrapper.csproj'
$solution = Join-Path $wrapper 'ShimmerLVWrapper.sln'
$buildOut = Join-Path $wrapper 'bin\Release'
$bin = Join-Path $repo 'ShimmerLabview\Bin'

function Fail([string]$message) {
    Write-Host "::error::$message"
    exit 1
}

function Set-Output([string]$name, [string]$value) {
    Write-Host "$name=$value"
    if ($env:GITHUB_OUTPUT) {
        # Without a BOM: Out-File would write one, and the runner would read it as part of the name
        [IO.File]::AppendAllText($env:GITHUB_OUTPUT, "$name=$value`n")
    }
}

function Get-PinnedVersion {
    [xml]$config = [IO.File]::ReadAllText($packagesConfig)
    $package = @($config.packages.package | Where-Object { $_.id -eq 'ShimmerAPI' })
    if ($package.Count -ne 1) { Fail "Expected one ShimmerAPI package in $packagesConfig, found $($package.Count)." }
    return $package[0].version
}

function Get-StableVersionsOnNuGet {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $index = Invoke-RestMethod 'https://api.nuget.org/v3-flatcontainer/shimmerapi/index.json'
    return @($index.versions | Where-Object { $_ -match '^\d+\.\d+\.\d+$' } | Sort-Object { [version]$_ })
}

# Replaces each pair's first string with its second, where the first appears exactly once. Keeps
# the file's byte order mark, or its lack of one, and its line endings.
function Edit-File([string]$path, [string[][]]$pairs) {
    $bytes = [IO.File]::ReadAllBytes($path)
    $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    $text = [IO.File]::ReadAllText($path)
    foreach ($pair in $pairs) {
        $count = [regex]::Matches($text, [regex]::Escape($pair[0])).Count
        if ($count -ne 1) { Fail "Expected '$($pair[0])' once in $path, found it $count times." }
        $text = $text.Replace($pair[0], $pair[1])
    }
    [IO.File]::WriteAllText($path, $text, (New-Object Text.UTF8Encoding($hasBom)))
}

function Set-Pin([string]$from, [string]$to) {
    Edit-File $packagesConfig @(, @("id=`"ShimmerAPI`" version=`"$from`"", "id=`"ShimmerAPI`" version=`"$to`""))
    Edit-File $project @(
        @("ShimmerAPI, Version=$from.0,", "ShimmerAPI, Version=$to.0,"),
        @("packages\ShimmerAPI.$from\", "packages\ShimmerAPI.$to\"))
}

function Build-Wrapper {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path $vswhere)) { Fail 'vswhere.exe was not found: install Visual Studio or the Build Tools, with MSBuild.' }
    $msbuild = & $vswhere -latest -products * -requires Microsoft.Component.MSBuild -find 'MSBuild\**\Bin\MSBuild.exe' | Select-Object -First 1
    if (-not $msbuild) { Fail 'vswhere found no MSBuild.' }
    # Through the solution: a packages.config restore of the project on its own has no solution
    # directory to restore into, and fails
    & $msbuild $solution -t:Restore -p:RestorePackagesConfig=true -v:quiet -nologo
    if ($LASTEXITCODE -ne 0) { Fail 'Restoring the wrapper''s NuGet packages failed.' }
    & $msbuild $solution -p:Configuration=Release -v:minimal -nologo
    if ($LASTEXITCODE -ne 0) { Fail 'Building the wrapper failed.' }
}

# The DLLs the wrapper needs, by file name: ShimmerLVWrapper.dll and every DLL in the build output
# its references reach. In a process of its own, because a reflection-only load lasts as long as the
# process does, and a second run in the same console would read the first run's assemblies.
function Get-NeededDlls {
    $walk = {
        param([string]$buildOut)
        $ErrorActionPreference = 'Stop'
        $framework = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319'
        function Test-InFramework([string]$name) {
            foreach ($path in "$framework\$name.dll", "$framework\WPF\$name.dll") {
                if (Test-Path $path) { return $true }
            }
            foreach ($gac in 'GAC_MSIL', 'GAC_64', 'GAC_32') {
                if (Test-Path (Join-Path $env:WINDIR "Microsoft.NET\assembly\$gac\$name")) { return $true }
            }
            return $false
        }
        $seen = @{}
        $queue = New-Object 'System.Collections.Generic.Queue[string]'
        $queue.Enqueue('ShimmerLVWrapper')
        while ($queue.Count -gt 0) {
            $name = $queue.Dequeue()
            if ($seen.ContainsKey($name)) { continue }
            $seen[$name] = $true
            $file = Join-Path $buildOut "$name.dll"
            if (Test-Path $file) {
                "$name.dll"
                foreach ($reference in [Reflection.Assembly]::ReflectionOnlyLoadFrom($file).GetReferencedAssemblies()) {
                    $queue.Enqueue($reference.Name)
                }
            } elseif (-not (Test-InFramework $name)) {
                throw "The wrapper needs $name, which neither the build output nor the .NET Framework has."
            }
        }
    }
    $job = Start-Job -ScriptBlock $walk -ArgumentList $buildOut
    try {
        return @(Receive-Job $job -Wait -ErrorAction Stop | Sort-Object)
    } catch {
        Fail $_.Exception.Message
    } finally {
        Remove-Job $job -Force
    }
}

# What is wrong with Bin/, if anything, as one line per problem
function Get-BinProblems([string[]]$needed, [string]$pinned) {
    $problems = @()
    foreach ($dll in $needed) {
        if (-not (Test-Path (Join-Path $bin $dll))) { $problems += "$dll is missing" }
    }
    $api = Join-Path $bin 'ShimmerAPI.dll'
    if (Test-Path $api) {
        $have = [Reflection.AssemblyName]::GetAssemblyName($api).Version
        if ($have -ne [version]"$pinned.0") { $problems += "ShimmerAPI.dll is $have, where the pin is $pinned" }
    }
    return $problems
}

function Assert-Bin([string]$pinned) {
    $needed = Get-NeededDlls
    $problems = @(Get-BinProblems $needed $pinned)
    if ($problems.Count -gt 0) {
        Fail ("ShimmerLabview/Bin/ is out of step with the wrapper: " + ($problems -join '; ') +
            ". Refresh it with: .\tools\Update-ShimmerApi.ps1 -Version $pinned")
    }
    Write-Host "ShimmerLabview/Bin/ holds the $($needed.Count) DLLs the wrapper needs, with ShimmerAPI $pinned`: $($needed -join ', ')"
}

$pinned = Get-PinnedVersion

if ($Check) {
    Build-Wrapper
    Assert-Bin $pinned
    exit 0
}

$stable = Get-StableVersionsOnNuGet
if ($stable.Count -eq 0) { Fail 'nuget.org lists no stable ShimmerAPI version.' }
if ($Version) {
    if ($Version -notmatch '^\d+\.\d+\.\d+$') { Fail "-Version needs a release version such as 1.4.0, not '$Version'." }
    if ($stable -notcontains $Version) { Fail "nuget.org has no ShimmerAPI $Version (it has $($stable -join ', '))." }
    $target = $Version
} else {
    $target = $stable[-1]
    if ([version]$target -le [version]$pinned) {
        Write-Host "The wrapper is on ShimmerAPI $pinned, and the newest on nuget.org is $target`: nothing to do."
        exit 0
    }
}

if ($target -ne $pinned) {
    Write-Host "Moving the wrapper from ShimmerAPI $pinned to $target"
    Set-Pin $pinned $target
} else {
    Write-Host "Rebuilding the wrapper on ShimmerAPI $pinned and refreshing ShimmerLabview/Bin/"
}
Build-Wrapper
$needed = Get-NeededDlls
# Without the folder, each copy would land on a file called Bin
New-Item -ItemType Directory -Force $bin | Out-Null
foreach ($dll in $needed) {
    Copy-Item (Join-Path $buildOut $dll) $bin -Force
}
# The wrapper's own symbols and config travel with it, as they always have in Bin/
foreach ($extra in 'ShimmerLVWrapper.pdb', 'ShimmerLVWrapper.dll.config') {
    $file = Join-Path $buildOut $extra
    if (Test-Path $file) { Copy-Item $file $bin -Force }
}
Assert-Bin $target
Set-Output 'from' $pinned
Set-Output 'to' $target
