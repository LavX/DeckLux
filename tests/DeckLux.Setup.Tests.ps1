# Copyright (c) 2026 Laszlo Toth <lavx@lavx.hu>.
# Licensed under the Microsoft Public License (MS-PL).

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $compiler -PathType Leaf)) {
    throw "64-bit .NET Framework C# compiler was not found: $compiler"
}

$testExecutable = Join-Path ([IO.Path]::GetTempPath()) `
    ('DeckLux.Setup.Tests.' + [Guid]::NewGuid().ToString('N') + '.exe')
try {
    $arguments = @(
        '/nologo',
        '/target:exe',
        '/platform:x64',
        '/optimize+',
        '/warn:4',
        '/warnaserror+',
        '/main:DeckLux.Setup.Tests.Program',
        "/out:$testExecutable",
        '/reference:System.dll',
        '/reference:System.Core.dll',
        '/reference:System.Drawing.dll',
        '/reference:System.Windows.Forms.dll',
        '/reference:System.Web.Extensions.dll',
        '/reference:System.IO.Compression.dll',
        '/reference:System.IO.Compression.FileSystem.dll',
        (Join-Path $projectRoot 'setup\DeckLux.Setup.cs'),
        (Join-Path $PSScriptRoot 'SetupStateTests.cs'))
    & $compiler @arguments
    if ($LASTEXITCODE -ne 0) {
        throw "DeckLux setup-state test compilation failed with exit code $LASTEXITCODE."
    }

    & $testExecutable
    if ($LASTEXITCODE -ne 0) {
        throw "DeckLux setup-state tests failed with exit code $LASTEXITCODE."
    }
}
finally {
    if (Test-Path -LiteralPath $testExecutable) {
        Remove-Item -LiteralPath $testExecutable -Force
    }
}
