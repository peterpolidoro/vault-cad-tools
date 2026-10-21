<#
.SYNOPSIS
Dot-source to compile a tiny C# helper for Inventor COM calls that PowerShell cannot make.

.DESCRIPTION
PowerShell's late-bound COM binder cannot pass the ByRef/out parameters some Inventor API
methods use (ComponentOccurrence.CreateGeometryProxy, TranslatorAddIn.Open). This compiles,
once per process, a static class against Autodesk's primary interop assembly
(Autodesk.Inventor.Interop.dll, installed with Inventor 2025; the Vault Explorer copy is the
fallback). No GUI, no extra packages; .NET Framework's in-box compiler is used by Add-Type.

    . (Join-Path $PSScriptRoot "Import-InventorInterop.ps1")
    $proxy  = [VaultCad.InventorInterop]::CreateGeometryProxy($occurrence, $workPlane)
    $target = [VaultCad.InventorInterop]::TranslatorOpen($translator, $medium, $context, $options)
#>
if (-not ('VaultCad.InventorInterop' -as [type])) {
    $candidates = @(
        "$env:ProgramFiles\Autodesk\Inventor 2025\Bin\Public Assemblies\Autodesk.Inventor.Interop.dll",
        "$env:ProgramFiles\Autodesk\Inventor 2025\Bin\Autodesk.Inventor.Interop.dll",
        "$env:ProgramFiles\Autodesk\Vault Client 2025\Explorer\Autodesk.Inventor.Interop.dll"
    )
    $interop = $candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $interop) { throw "Autodesk.Inventor.Interop.dll not found in: $($candidates -join '; ')" }
    # The interop assembly is not in the GAC or the probing path; load it explicitly and answer
    # the runtime's by-name binding requests for it, otherwise the compiled helper fails at call time.
    $script:InventorInteropLoaded = [Reflection.Assembly]::LoadFrom($interop)
    $resolver = [ResolveEventHandler] {
        param($sender, $eventArgs)
        if ($eventArgs.Name -like 'Autodesk.Inventor.Interop,*') { return $script:InventorInteropLoaded }
        return $null
    }
    [AppDomain]::CurrentDomain.add_AssemblyResolve($resolver)
    $code = @"
using System;
using Inventor;
namespace VaultCad {
    public static class InventorInterop {
        public static string InteropAssembly { get { return typeof(Inventor.Application).Assembly.Location; } }
        public static object CreateGeometryProxy(object occurrence, object geometry) {
            object proxy;
            ((ComponentOccurrence)occurrence).CreateGeometryProxy(geometry, out proxy);
            return proxy;
        }
        public static object TranslatorOpen(object translator, object medium, object context, object options) {
            object target;
            ((TranslatorAddIn)translator).Open((DataMedium)medium, (TranslationContext)context, (NameValueMap)options, out target);
            return target;
        }
    }
}
"@
    Add-Type -TypeDefinition $code -ReferencedAssemblies $interop -ErrorAction Stop
    Write-Verbose "Compiled VaultCad.InventorInterop against $interop"
}
