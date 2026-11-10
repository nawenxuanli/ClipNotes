param(
    [Parameter(Mandatory=$true)][string]$Identity,
    [Parameter(Mandatory=$true)][string]$Publisher,
    [string]$DisplayName = "ClipNotes",
    [string]$PublisherDisplayName = "ClipNotes",
    [string]$Version = "2.1.0.0"
)
$ErrorActionPreference = 'Stop'
if ($Version -notmatch '^\d+\.\d+\.\d+\.0$') { throw 'Use a four-part version ending in .0.' }
$makeappx = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\bin\*\x64\makeappx.exe" |
    Sort-Object { [version]$_.Directory.Parent.Name } -Descending | Select-Object -First 1
if (!$makeappx) { throw 'Install the Windows SDK with MakeAppx.' }
$inputDir = Join-Path $PWD 'dist\ClipNotes'
if (!(Test-Path (Join-Path $inputDir 'ClipNotes.exe'))) { throw 'Build the Windows executable before packaging.' }
$stage = Join-Path $PWD "build\msix"
if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
New-Item -ItemType Directory "$stage\Assets" -Force | Out-Null
Copy-Item "$inputDir\*" $stage -Recurse
$env:QT_QPA_PLATFORM = 'offscreen'
python -c "from PySide6.QtGui import QImage; from pathlib import Path; a=Path('build/msix/Assets'); sizes={'StoreLogo':50,'Square150x150Logo':150,'Square44x44Logo':44}; exec('for name, size in sizes.items():\n image=QImage(size,size,QImage.Format.Format_RGB32)\n image.fill(0x10483f)\n assert image.save(str(a/(name+chr(46)+chr(112)+chr(110)+chr(103))))')"
if ($LASTEXITCODE) { throw 'Could not generate package logos.' }
$Identity = [Security.SecurityElement]::Escape($Identity)
$Publisher = [Security.SecurityElement]::Escape($Publisher)
$DisplayName = [Security.SecurityElement]::Escape($DisplayName)
$PublisherDisplayName = [Security.SecurityElement]::Escape($PublisherDisplayName)
@"
<?xml version="1.0" encoding="utf-8"?>
<Package xmlns="http://schemas.microsoft.com/appx/manifest/foundation/windows10"
         xmlns:uap="http://schemas.microsoft.com/appx/manifest/uap/windows10"
         xmlns:rescap="http://schemas.microsoft.com/appx/manifest/foundation/windows10/restrictedcapabilities"
         IgnorableNamespaces="uap rescap">
  <Identity Name="$Identity" Publisher="$Publisher" Version="$Version" ProcessorArchitecture="x64"/>
  <Properties>
    <DisplayName>$DisplayName</DisplayName>
    <PublisherDisplayName>$PublisherDisplayName</PublisherDisplayName>
    <Logo>Assets\StoreLogo.png</Logo>
  </Properties>
  <Resources><Resource Language="en-us"/></Resources>
  <Dependencies><TargetDeviceFamily Name="Windows.Desktop" MinVersion="10.0.19041.0" MaxVersionTested="10.0.26100.0"/></Dependencies>
  <Applications>
    <Application Id="ClipNotes" Executable="ClipNotes.exe" EntryPoint="Windows.FullTrustApplication">
      <uap:VisualElements DisplayName="$DisplayName" Description="Search recorded courses and save timestamped study notes."
        BackgroundColor="transparent" Square150x150Logo="Assets\Square150x150Logo.png" Square44x44Logo="Assets\Square44x44Logo.png"/>
    </Application>
  </Applications>
  <Capabilities><rescap:Capability Name="runFullTrust"/></Capabilities>
</Package>
"@ | Set-Content -Encoding utf8 "$stage\AppxManifest.xml"
& $makeappx.FullName pack /d $stage /p "dist\ClipNotes-$Version-x64.msix" /o
if ($LASTEXITCODE) { throw 'MakeAppx failed.' }
