#Requires -Version 5.1
<#
Builds a separate ERF with the quick-launch form using a local 1C Designer.
No production infobase changes. Requires access to a TEST infobase.
Example:
.\scripts\build-quick-launch.ps1 -DesignerExe "C:\Program Files\1cv8\8.3.27.2074\bin\1cv8.exe" -InfoBase "C:\Bases\Test"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$DesignerExe,
    [Parameter(Mandatory=$true)][string]$InfoBase,
    [ValidateSet('F','S')][string]$ConnectionMode='F',
    [string]$OutputErf='',
    [switch]$Overwrite,
    [switch]$KeepWork
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$repo=(Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$designer=(Resolve-Path -LiteralPath $DesignerExe).Path
$source=Join-Path $repo 'АнализЗамеровПроизводительности.erf'
$formXml=Join-Path $repo 'src\ФормаОтчета\Ext\Form.xml'
$formBsl=Join-Path $repo 'src\ФормаОтчета\Ext\Form\Module.bsl'
foreach ($file in @($source,$formXml,$formBsl)) {
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "Missing source: $file" }
}
if ($ConnectionMode -eq 'F' -and -not (Test-Path -LiteralPath $InfoBase -PathType Container)) {
    throw "Test file infobase not found: $InfoBase"
}
if ([string]::IsNullOrWhiteSpace($OutputErf)) {
    $OutputErf=Join-Path $repo 'dist\АнализЗамеровПроизводительности.БыстрыйЗапуск.erf'
}
$out=[IO.Path]::GetFullPath($OutputErf)
if ([string]::Equals($out,[IO.Path]::GetFullPath($source),[StringComparison]::OrdinalIgnoreCase)) {
    throw 'Refusing to overwrite the original ERF.'
}
if ((Test-Path -LiteralPath $out) -and -not $Overwrite) {
    throw "Output already exists: $out (use -Overwrite explicitly)."
}
$sourceHash=(Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
$work=Join-Path ([IO.Path]::GetTempPath()) ('1c-quick-launch-' + [guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $work
$rootXml=Join-Path $work 'АнализЗамеровПроизводительности.xml'
$tempErf=Join-Path $work 'quick-launch.erf'
function Invoke-Designer([string[]]$argsList,[string]$log) {
    & $designer @argsList
    if ($LASTEXITCODE -ne 0) { throw "Designer error $LASTEXITCODE; check log $log" }
}
try {
    $baseArgs=@('DESIGNER',('/'+$ConnectionMode),$InfoBase,'/DisableStartupMessages')
    $log=Join-Path $work 'dump.log'
    Invoke-Designer ($baseArgs+@('/DumpExternalDataProcessorOrReportToFiles',$rootXml,$source,'-Format','Hierarchical','/Out',$log)) $log
    if (-not (Test-Path -LiteralPath $rootXml -PathType Leaf)) { throw 'Designer did not export the ERF.' }

    $meta=New-Object System.Xml.XmlDocument
    $meta.PreserveWhitespace=$true
    $meta.Load($rootXml)
    $report=$meta.DocumentElement.SelectSingleNode("*[local-name()='ExternalReport']")
    if ($null -eq $report) { throw 'Dumped root is not an ExternalReport.' }
    $props=$report.SelectSingleNode("*[local-name()='Properties']")
    $children=$report.SelectSingleNode("*[local-name()='ChildObjects']")
    $name=$props.SelectSingleNode("*[local-name()='Name']")
    $default=$props.SelectSingleNode("*[local-name()='DefaultForm']")
    $schema=$props.SelectSingleNode("*[local-name()='MainDataCompositionSchema']")
    if ($null -eq $children -or $null -eq $name -or $null -eq $default -or $null -eq $schema) {
        throw 'Unexpected metadata layout.'
    }
    if ($name.InnerText -ne 'АнализЗамеровПроизводительности' -or
        $schema.InnerText -ne 'ExternalReport.АнализЗамеровПроизводительности.Template.ОсновнаяСхемаКомпоновкиДанных') {
        throw 'Unexpected name or main DCS: refuse to modify.'
    }
    if ($children.SelectNodes("*[local-name()='Form']").Count -ne 0 -or
        -not [string]::IsNullOrWhiteSpace($default.InnerText)) {
        throw 'Baseline ERF already contains a form: refuse overlay.'
    }
    $firstTemplate=$children.SelectSingleNode("*[local-name()='Template']")
    if ($null -eq $firstTemplate) { throw 'Baseline report has no DCS template.' }
    $default.InnerText='ExternalReport.АнализЗамеровПроизводительности.Form.ФормаОтчета'
    $formRef=$meta.CreateElement('Form',$meta.DocumentElement.NamespaceURI)
    $formRef.InnerText='ФормаОтчета'
    $null=$children.InsertBefore($formRef,$firstTemplate)
    $meta.Save($rootXml)

    $forms=Join-Path $work 'АнализЗамеровПроизводительности\Forms'
    $formExt=Join-Path $forms 'ФормаОтчета\Ext'
    $moduleDir=Join-Path $formExt 'Form'
    $null=New-Item -ItemType Directory -Force -Path $moduleDir
    $formContent=[IO.File]::ReadAllText($formXml)
    $old='<v8:Type>cfg:ReportObject</v8:Type>'
    $new='<v8:Type>cfg:ExternalReportObject.АнализЗамеровПроизводительности</v8:Type>'
    if ($formContent.Split(@($old),[StringSplitOptions]::None).Count -ne 2) {
        throw 'Unexpected form main-attribute type.'
    }
    $utf8=New-Object System.Text.UTF8Encoding($true)
    [IO.File]::WriteAllText((Join-Path $formExt 'Form.xml'),$formContent.Replace($old,$new),$utf8)
    Copy-Item -LiteralPath $formBsl -Destination (Join-Path $moduleDir 'Module.bsl')

    $formMeta=@'
<?xml version="1.0" encoding="UTF-8"?>
<MetaDataObject xmlns="http://v8.1c.ru/8.3/MDClasses" xmlns:app="http://v8.1c.ru/8.2/managed-application/core" xmlns:v8="http://v8.1c.ru/8.1/data/core" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" version="2.20">
  <Form uuid="e0261a47-681c-4c07-b8ac-d22659c076f4">
    <Properties>
      <Name>ФормаОтчета</Name>
      <Synonym><v8:item><v8:lang>ru</v8:lang><v8:content>Анализ производительности</v8:content></v8:item></Synonym>
      <Comment/>
      <FormType>Managed</FormType>
      <IncludeHelpInContents>false</IncludeHelpInContents>
      <UsePurposes><v8:Value xsi:type="app:ApplicationUsePurpose">PlatformApplication</v8:Value></UsePurposes>
      <ExtendedPresentation/>
    </Properties>
  </Form>
</MetaDataObject>
'@
    [IO.File]::WriteAllText((Join-Path $forms 'ФормаОтчета.xml'),$formMeta,$utf8)
    $log=Join-Path $work 'load.log'
    Invoke-Designer ($baseArgs+@('/LoadExternalDataProcessorOrReportFromFiles',$rootXml,$tempErf,'/Out',$log)) $log
    if (-not (Test-Path -LiteralPath $tempErf -PathType Leaf) -or (Get-Item $tempErf).Length -le 0) {
        throw 'Designer did not build a nonempty ERF.'
    }
    if ((Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash -ne $sourceHash) {
        throw 'Original ERF changed during build.'
    }
    $outDir=Split-Path -Path $out -Parent
    if (-not (Test-Path -LiteralPath $outDir)) {
        $null=New-Item -ItemType Directory -Force -Path $outDir
    }
    Copy-Item -LiteralPath $tempErf -Destination $out -Force
    Write-Output "Built: $out"
    Write-Output "Source SHA256: $sourceHash"
    Write-Output "Build SHA256: $((Get-FileHash -LiteralPath $out -Algorithm SHA256).Hash)"
    Write-Output 'Assembly is not a runtime test. Validate the ERF in 1C before release.'
} finally {
    if ($KeepWork) { Write-Output "Work: $work" }
    else { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
}
