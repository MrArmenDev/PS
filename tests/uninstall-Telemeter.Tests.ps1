# No Windows operations are executed: load function definitions only and mock OS calls.
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$sourcePath = Join-Path $PSScriptRoot "../uninstall-Telemeter.ps1"
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
	$sourcePath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) {
	throw ($parseErrors.Message -join "`n")
}
foreach ($definition in $ast.FindAll({
	param($node)
	$node -is [Management.Automation.Language.FunctionDefinitionAst]
}, $false)) {
	Invoke-Expression $definition.Extent.Text
}
$legacyServiceNames = @("WinTelemetrySvc")
$legacyTaskNames = @("WinTelemetrySvcMaintenance")
$TimeoutSeconds = 1
$script:passed = 0

function Assert-Equal {
	param($Actual, $Expected)
	if ($Actual -cne $Expected) {
		throw "Expected '$Expected', got '$Actual'."
	}
}

function Test-Case {
	param([string]$Name, [scriptblock]$Body)
	$script:cleanupErrors = New-Object 'System.Collections.Generic.List[string]'
	$script:targetPaths = @()
	$script:deleteRequested = @()
	& $Body
	$script:passed++
	Write-Host "PASS: $Name"
}

function New-Remaining {
	param($Services = @(), $Tasks = @(), $Paths = @(), $Processes = @())
	[PSCustomObject]@{
		Services = @($Services)
		Tasks = @($Tasks)
		Paths = @($Paths)
		Processes = @($Processes)
	}
}

function Invoke-EntryForTest {
	# A synthetic entry point needs a saved path and returns instead of exits.
	$entry = $ast.EndBlock.Statements[-1].Extent.Text.
		Replace("exit (Get-CleanupExitCode)", "return (Get-CleanupExitCode)").
		Replace("exit 1", "return 1").
		Replace('exit $childCode', 'return $childCode')
	$script:cleanupScriptPath = $sourcePath
	$previousOS = $env:OS
	try {
		$env:OS = "Windows_NT"
		& ([scriptblock]::Create($entry))
	}
	finally {
		$env:OS = $previousOS
	}
}

Test-Case "Empty verification succeeds" {
	function Get-RemainingLegacyItems { New-Remaining }
	Assert-Equal (Get-CleanupExitCode) 0
}
Test-Case "A deleted service still visible requires restart" {
	$script:deleteRequested = @("WinTelemetrySvc")
	function Get-RemainingLegacyItems {
		New-Remaining -Services ([PSCustomObject]@{ Name = "WinTelemetrySvc"; State = "Stopped" })
	}
	Assert-Equal (Get-CleanupExitCode) 3010
}
Test-Case "An undeleted service is failure, not restart success" {
	function Get-RemainingLegacyItems {
		New-Remaining -Services ([PSCustomObject]@{ Name = "WinTelemetrySvc"; State = "Running" })
	}
	Assert-Equal (Get-CleanupExitCode) 1
}
Test-Case "SYSTEM profile files prevent success" {
	function Get-RemainingLegacyItems {
		New-Remaining -Paths "C:\Windows\System32\config\systemprofile\AppData\Local\TelemetryUpdatePC"
	}
	Assert-Equal (Get-CleanupExitCode) 1
}
Test-Case "Nested tasks prevent success" {
	function Get-RemainingLegacyItems {
		New-Remaining -Tasks ([PSCustomObject]@{ TaskPath = "\Nested\"; TaskName = "WinTelemetrySvcMaintenance" })
	}
	Assert-Equal (Get-CleanupExitCode) 1
}
Test-Case "Live processes prevent success" {
	function Get-RemainingLegacyItems {
		New-Remaining -Processes ([PSCustomObject]@{ ProcessId = 42 })
	}
	Assert-Equal (Get-CleanupExitCode) 1
}
Test-Case "Cleanup errors prevent success even without leftovers" {
	Invoke-CleanupAction "Denied access" { throw "Access denied" }
	function Get-RemainingLegacyItems { New-Remaining }
	Assert-Equal (Get-CleanupExitCode) 1
}
Test-Case "Verification errors propagate instead of returning absence" {
	function Get-LegacyServices { throw "Service enumeration denied" }
	$caught = $false
	try { Get-RemainingLegacyItems } catch { $caught = $true }
	Assert-Equal $caught $true
}
Test-Case "A remaining service registry key is not mistaken for absence" {
	function Get-CimInstance {}
	function Test-Path { $true }
	$services = @(Get-LegacyServices)
	Assert-Equal $services.Count 1
	Assert-Equal $services[0].Name "WinTelemetrySvc"
	Assert-Equal $services[0].State "Registry entry remains"
}
Test-Case "A fully absent service is idempotent" {
	function Get-CimInstance {}
	function Test-Path { $false }
	Assert-Equal (@(Get-LegacyServices).Count) 0
}
Test-Case "Task discovery matches exact names across all task paths" {
	function Get-ScheduledTask {
		[PSCustomObject]@{ TaskName = "WinTelemetrySvcMaintenance"; TaskPath = "\Nested\" }
		[PSCustomObject]@{ TaskName = "WinTelemetrySvcMaintenanceNew"; TaskPath = "\" }
	}
	$tasks = @(Get-LegacyTasks)
	Assert-Equal $tasks.Count 1
	Assert-Equal $tasks[0].TaskPath "\Nested\"
}
Test-Case "Task removal preserves full task path and order" {
	$calls = New-Object 'System.Collections.Generic.List[string]'
	function Get-ScheduledTask {
		[PSCustomObject]@{ TaskName = "WinTelemetrySvcMaintenance"; TaskPath = "\Nested\" }
	}
	function Disable-ScheduledTask { param($TaskName, $TaskPath) $calls.Add("disable:$TaskPath$TaskName") }
	function Stop-ScheduledTask { param($TaskName, $TaskPath) $calls.Add("stop:$TaskPath$TaskName") }
	function Unregister-ScheduledTask { param($TaskName, $TaskPath, $Confirm) $calls.Add("delete:$TaskPath$TaskName") }
	Remove-LegacyTasks
	Assert-Equal ($calls -join ",") "disable:\Nested\WinTelemetrySvcMaintenance,stop:\Nested\WinTelemetrySvcMaintenance,delete:\Nested\WinTelemetrySvcMaintenance"
}
Test-Case "A task stop failure does not prevent unregistering" {
	$calls = New-Object 'System.Collections.Generic.List[string]'
	function Get-ScheduledTask {
		[PSCustomObject]@{ TaskName = "WinTelemetrySvcMaintenance"; TaskPath = "\"; State = "Running" }
	}
	function Disable-ScheduledTask {}
	function Stop-ScheduledTask { throw "Task stop denied" }
	function Unregister-ScheduledTask { param($Confirm) $calls.Add("delete") }
	Remove-LegacyTasks
	Assert-Equal ($calls -join ",") "delete"
	Assert-Equal $script:cleanupErrors.Count 1
}
Test-Case "A task already stopped is idempotent" {
	function Get-ScheduledTask {
		[PSCustomObject]@{ TaskName = "WinTelemetrySvcMaintenance"; TaskPath = "\"; State = "Disabled" }
	}
	function Disable-ScheduledTask {}
	function Stop-ScheduledTask { throw "Task not running" }
	function Unregister-ScheduledTask { param($Confirm) }
	Remove-LegacyTasks
	Assert-Equal $script:cleanupErrors.Count 0
}
foreach ($nativeCode in @(0, 1060, 1072)) {
	Test-Case "Service deletion handles native exit code $nativeCode" {
		function Get-CimInstance { [PSCustomObject]@{ State = "Stopped" } }
		function Invoke-CimMethod { [PSCustomObject]@{ ReturnValue = 0 } }
		function Test-Sc { $global:LASTEXITCODE = $nativeCode }
		Set-Alias -Name "$env:WINDIR\System32\sc.exe" -Value Test-Sc
		Remove-LegacyServices
		Assert-Equal $script:cleanupErrors.Count 0
		Assert-Equal $script:deleteRequested.Count ([int]($nativeCode -in @(0, 1072)))
	}
}
Test-Case "Access-denied deletion resets the descriptor and retries" {
	$state = @{ Deletes = 0; SdSet = 0 }
	function Get-CimInstance { [PSCustomObject]@{ State = "Stopped" } }
	function Invoke-CimMethod { [PSCustomObject]@{ ReturnValue = 0 } }
	function Test-Sc {
		if ($args[0] -eq "delete") {
			$state.Deletes++
			$global:LASTEXITCODE = $(if ($state.Deletes -eq 1) { 5 } else { 0 })
		}
		else {
			if ($args[0] -eq "sdset") { $state.SdSet++ }
			$global:LASTEXITCODE = 0
		}
	}
	Set-Alias -Name "$env:WINDIR\System32\sc.exe" -Value Test-Sc
	Remove-LegacyServices
	Assert-Equal $state.SdSet 1
	Assert-Equal $state.Deletes 2
	Assert-Equal $script:deleteRequested.Count 1
	Assert-Equal $script:cleanupErrors.Count 0
}
Test-Case "A still-protected service falls back to registry key removal" {
	$state = @{ Removed = $false }
	function Get-CimInstance { [PSCustomObject]@{ State = "Stopped" } }
	function Invoke-CimMethod { [PSCustomObject]@{ ReturnValue = 0 } }
	function Test-Sc { $global:LASTEXITCODE = 5 }
	Set-Alias -Name "$env:WINDIR\System32\sc.exe" -Value Test-Sc
	function Remove-LegacyServiceKey { param($Name) $state.Removed = $true; $true }
	Remove-LegacyServices
	Assert-Equal $state.Removed $true
	Assert-Equal $script:deleteRequested.Count 1
	Assert-Equal $script:cleanupErrors.Count 0
}
Test-Case "A service resisting every removal is a failure" {
	function Get-CimInstance { [PSCustomObject]@{ State = "Stopped" } }
	function Invoke-CimMethod { [PSCustomObject]@{ ReturnValue = 0 } }
	function Test-Sc { $global:LASTEXITCODE = 5 }
	Set-Alias -Name "$env:WINDIR\System32\sc.exe" -Value Test-Sc
	function Remove-LegacyServiceKey { param($Name) throw "Registry key is protected" }
	Remove-LegacyServices
	Assert-Equal $script:deleteRequested.Count 0
	Assert-Equal $script:cleanupErrors.Count 1
	Assert-Equal ($script:cleanupErrors[0] -like "*protected*") $true
}
Test-Case "Service stop completion is awaited before delete" {
	$state = @{ Queries = 0; StopRequested = $false; DeleteCalled = $false }
	function Get-CimInstance {
		$state.Queries++
		[PSCustomObject]@{ State = $(if ($state.Queries -lt 3) { "Stop Pending" } else { "Stopped" }) }
	}
	function Invoke-CimMethod {
		param($InputObject, $MethodName, $Arguments)
		if ($MethodName -eq "StopService") { $state.StopRequested = $true }
		[PSCustomObject]@{ ReturnValue = 0 }
	}
	function Start-Sleep {}
	function Test-Sc {
		Assert-Equal $state.StopRequested $true
		Assert-Equal ($state.Queries -ge 3) $true
		$state.DeleteCalled = $true
		$global:LASTEXITCODE = 0
	}
	Set-Alias -Name "$env:WINDIR\System32\sc.exe" -Value Test-Sc
	Remove-LegacyServices
	Assert-Equal $state.DeleteCalled $true
	Assert-Equal $script:cleanupErrors.Count 0
}
Test-Case "Stop failure still permits a service deletion attempt" {
	$state = @{ DeleteCalled = $false }
	function Get-CimInstance { [PSCustomObject]@{ State = "Running" } }
	function Invoke-CimMethod {
		param($InputObject, $MethodName, $Arguments)
		if ($MethodName -eq "StopService") { throw "Cannot stop" }
		[PSCustomObject]@{ ReturnValue = 0 }
	}
	function Test-Sc {
		$state.DeleteCalled = $true
		$global:LASTEXITCODE = 0
	}
	Set-Alias -Name "$env:WINDIR\System32\sc.exe" -Value Test-Sc
	Remove-LegacyServices
	Assert-Equal $state.DeleteCalled $true
	Assert-Equal $script:cleanupErrors.Count 1
}
Test-Case "Already marked services are handled even if CIM no longer enumerates them" {
	function Get-CimInstance {}
	function Test-Sc { $global:LASTEXITCODE = 1072 }
	Set-Alias -Name "$env:WINDIR\System32\sc.exe" -Value Test-Sc
	Remove-LegacyServices
	Assert-Equal $script:deleteRequested.Count 1
	Assert-Equal $script:cleanupErrors.Count 0
}
Test-Case "Service stop wait respects the configured timeout" {
	$elapsed = [Diagnostics.Stopwatch]::StartNew()
	function Get-CimInstance { [PSCustomObject]@{ State = "Running" } }
	function Invoke-CimMethod { [PSCustomObject]@{ ReturnValue = 0 } }
	function Test-Sc { $global:LASTEXITCODE = 0 }
	Set-Alias -Name "$env:WINDIR\System32\sc.exe" -Value Test-Sc
	Remove-LegacyServices
	Assert-Equal ($elapsed.Elapsed.TotalSeconds -ge $TimeoutSeconds) $true
	Assert-Equal ($elapsed.Elapsed.TotalSeconds -lt ($TimeoutSeconds + 3)) $true
	Assert-Equal $script:deleteRequested.Count 1
}
Test-Case "Processes use executable location, not executable name" {
	$script:targetPaths = @("C:\Users\A\AppData\Local\TelemetryUpdatePC")
	function Get-CimInstance {
		[PSCustomObject]@{ Name = "renamed.exe"; ProcessId = 1; ExecutablePath = "C:\Users\A\AppData\Local\TelemetryUpdatePC\renamed.exe" }
		[PSCustomObject]@{ Name = "TelemetryMainUpdate.exe"; ProcessId = 2; ExecutablePath = "C:\Other\TelemetryMainUpdate.exe" }
		[PSCustomObject]@{ Name = "other.exe"; ProcessId = 3; ExecutablePath = "C:\Users\A\AppData\Local\TelemetryUpdatePC-other\other.exe" }
	}
	$found = @(Get-LegacyProcesses)
	Assert-Equal $found.Count 1
	Assert-Equal $found[0].ProcessId 1
}
Test-Case "Unidentifiable telemetry processes are errors" {
	function Get-CimInstance {
		[PSCustomObject]@{ Name = "TelemetryMainUpdate.exe"; ProcessId = 42; ExecutablePath = $null }
	}
	$caught = $false
	try { Get-LegacyProcesses } catch { $caught = $true }
	Assert-Equal $caught $true
}
Test-Case "PID reuse is rejected before termination" {
	function Get-LegacyProcesses {
		[PSCustomObject]@{ ProcessId = 42; CreationDate = 1; ExecutablePath = "old.exe" }
	}
	function Get-CimInstance {
		[PSCustomObject]@{ CreationDate = 2; ExecutablePath = "new.exe" }
	}
	function Invoke-CimMethod { throw "Must not terminate a reused PID" }
	Stop-LegacyProcesses
	Assert-Equal $script:cleanupErrors.Count 1
	Assert-Equal ($script:cleanupErrors[0] -like "*changed identity*") $true
}
Test-Case "Process termination failure is reported" {
	function Get-LegacyProcesses {
		[PSCustomObject]@{ ProcessId = 42; CreationDate = 1; ExecutablePath = "old.exe" }
	}
	function Get-CimInstance {
		[PSCustomObject]@{ CreationDate = 1; ExecutablePath = "old.exe" }
	}
	function Invoke-CimMethod { [PSCustomObject]@{ ReturnValue = 2 } }
	Stop-LegacyProcesses
	Assert-Equal $script:cleanupErrors.Count 1
	Assert-Equal ($script:cleanupErrors[0] -like "*returned 2*") $true
}
Test-Case "Reparse point deletion is refused" {
	$script:targetPaths = @("deployment")
	function Test-Path { $true }
	function Get-Item { [PSCustomObject]@{ Attributes = [IO.FileAttributes]::ReparsePoint } }
	function Remove-Item { throw "Must not follow link" }
	Remove-LegacyFiles
	Assert-Equal $script:cleanupErrors.Count 1
	Assert-Equal ($script:cleanupErrors[0] -like "*reparse point*") $true
}
Test-Case "Disappeared files are idempotent" {
	$script:targetPaths = @("deployment")
	function Test-Path { $false }
	Remove-LegacyFiles
	Assert-Equal $script:cleanupErrors.Count 0
}
Test-Case "Links nested inside a deployment are refused" {
	$script:targetPaths = @("deployment")
	function Test-Path { $true }
	function Get-Item { [PSCustomObject]@{ Attributes = [IO.FileAttributes]::Directory; PSIsContainer = $true } }
	function Get-ChildItem {
		[PSCustomObject]@{ Attributes = [IO.FileAttributes]::ReparsePoint; FullName = "deployment/link" }
	}
	function Remove-Item { throw "Must not delete through a link" }
	Remove-LegacyFiles
	Assert-Equal $script:cleanupErrors.Count 1
	Assert-Equal ($script:cleanupErrors[0] -like "*Reparse point inside*") $true
}
Test-Case "Locked files are explicit failures" {
	$script:targetPaths = @("deployment")
	function Test-Path { $true }
	function Get-Item { [PSCustomObject]@{ Attributes = [IO.FileAttributes]::Normal; PSIsContainer = $false } }
	function Remove-Item { throw "File locked" }
	Remove-LegacyFiles
	Assert-Equal $script:cleanupErrors.Count 1
	Assert-Equal ($script:cleanupErrors[0] -like "*File locked*") $true
}
Test-Case "Successful file deletion is verified" {
	$script:targetPaths = @("deployment")
	$state = @{ Exists = $true }
	function Test-Path { $state.Exists }
	function Get-Item { [PSCustomObject]@{ Attributes = [IO.FileAttributes]::Normal; PSIsContainer = $false } }
	function Remove-Item { $state.Exists = $false }
	Remove-LegacyFiles
	Assert-Equal $state.Exists $false
	Assert-Equal $script:cleanupErrors.Count 0
}
Test-Case "Profile discovery includes SYSTEM, alternate drives and wildcard suffixes" {
	function Join-Path { param($Path, $ChildPath) "$Path\$ChildPath" }
	function Test-Path { $true }
	function Get-ItemProperty { [PSCustomObject]@{ ProfileImagePath = "D:\Profiles\Alice" } }
	function Get-ChildItem {
		param($LiteralPath, [switch]$Directory, [switch]$Force)
		if ($LiteralPath -like "HKLM:*") {
			[PSCustomObject]@{ PSPath = "registered-profile" }
		}
		elseif ($LiteralPath -like "*\Users") {
			[PSCustomObject]@{ FullName = "C:\Users\Bob"; Attributes = [IO.FileAttributes]::Directory }
		}
		else {
			[PSCustomObject]@{ Name = "TelemetryUpdateOldPC"; FullName = "$LiteralPath\TelemetryUpdateOldPC" }
			[PSCustomObject]@{ Name = "TelemetryUpdateNew"; FullName = "$LiteralPath\TelemetryUpdateNew" }
			[PSCustomObject]@{ Name = "Unrelated"; FullName = "$LiteralPath\Unrelated" }
		}
	}
	$found = @(Get-LegacyPaths)
	Assert-Equal (@($found | Where-Object { $_ -like "*systemprofile*" }).Count -gt 0) $true
	Assert-Equal ($found -contains "D:\Profiles\Alice\AppData\Local\TelemetryUpdateOldPC") $true
	Assert-Equal ($found -contains "C:\Users\Bob\AppData\Local\TelemetryUpdateNew") $true
	Assert-Equal (@($found | Where-Object { $_ -like "*Unrelated" }).Count) 0
	Assert-Equal $script:cleanupErrors.Count 0
}
Test-Case "Failed profile enumeration is recorded while other roots are still inspected" {
	function Join-Path { param($Path, $ChildPath) "$Path\$ChildPath" }
	function Test-Path { $true }
	function Get-ChildItem {
		param($LiteralPath, [switch]$Directory, [switch]$Force)
		if ($LiteralPath -like "HKLM:*") { throw "Registry denied" }
		if ($LiteralPath -like "*\Users") { return }
		[PSCustomObject]@{ Name = "TelemetryUpdatePC"; FullName = "$LiteralPath\TelemetryUpdatePC" }
	}
	$found = @(Get-LegacyPaths)
	Assert-Equal ($found.Count -gt 0) $true
	Assert-Equal $script:cleanupErrors.Count 1
}
Test-Case "Previously discovered paths remain in final verification" {
	$script:targetPaths = @("old-deployment")
	function Get-LegacyServices {}
	function Get-LegacyTasks {}
	function Get-LegacyProcesses {}
	function Get-LegacyPaths { "new-deployment" }
	function Test-Path { $true }
	$remaining = Get-RemainingLegacyItems
	Assert-Equal ($remaining.Paths -join ",") "new-deployment,old-deployment"
	Assert-Equal ($script:targetPaths -join ",") "new-deployment,old-deployment"
}
Test-Case "Existing untrusted PsExec is rejected" {
	$PsExecPath = "untrusted.exe"
	function Test-Path { $true }
	function Get-AuthenticodeSignature {
		[PSCustomObject]@{ Status = "NotSigned"; SignerCertificate = $null }
	}
	$caught = $false
	try { Ensure-PsExec } catch { $caught = $_.Exception.Message -like "*valid Microsoft*" }
	Assert-Equal $caught $true
}
Test-Case "Non-HTTPS PsExec download is rejected" {
	$PsExecPath = "missing.exe"
	$PsExecUrl = "http://example.invalid/PsExec.exe"
	function Test-Path { $false }
	function Invoke-WebRequest { throw "Must not download over HTTP" }
	$caught = $false
	try { Ensure-PsExec } catch { $caught = $_.Exception.Message -like "*HTTPS*" }
	Assert-Equal $caught $true
}
Test-Case "A valid Microsoft-signed PsExec is accepted" {
	$PsExecPath = "trusted.exe"
	function Test-Path { $true }
	function Get-AuthenticodeSignature {
		[PSCustomObject]@{
			Status = "Valid"
			SignerCertificate = [PSCustomObject]@{ Subject = "CN=Microsoft Corporation, O=Microsoft Corporation, C=US" }
		}
	}
	function Resolve-Path { [PSCustomObject]@{ ProviderPath = "resolved-trusted.exe" } }
	Assert-Equal (Ensure-PsExec) "resolved-trusted.exe"
}
Test-Case "A failed download cleans its partial file, not an existing executable" {
	$PsExecPath = "missing.exe"
	$PsExecUrl = "https://example.invalid/PsExec.exe"
	$state = @{ Partial = $null; Removed = $null }
	function Test-Path { param($LiteralPath) $LiteralPath -eq $state.Partial }
	function Invoke-WebRequest {
		param($Uri, $OutFile, [switch]$UseBasicParsing, $TimeoutSec)
		Assert-Equal $TimeoutSec $TimeoutSeconds
		$state.Partial = $OutFile
		throw "Download interrupted"
	}
	function Remove-Item { param($LiteralPath, [switch]$Force) $state.Removed = $LiteralPath }
	$caught = $false
	try { Ensure-PsExec } catch { $caught = $_.Exception.Message -like "*Download interrupted*" }
	Assert-Equal $caught $true
	Assert-Equal ($state.Removed -like "missing.exe.*.download.exe") $true
	Assert-Equal ($state.Removed -eq $PsExecPath) $false
}
Test-Case "A downloaded PsExec is published only after signature verification" {
	$PsExecPath = "missing.exe"
	$PsExecUrl = "https://example.invalid/PsExec.exe"
	$state = @{ Signed = $false; Moved = $false }
	function Test-Path { $false }
	function Invoke-WebRequest {}
	function Get-AuthenticodeSignature {
		$state.Signed = $true
		[PSCustomObject]@{
			Status = "Valid"
			SignerCertificate = [PSCustomObject]@{ Subject = "O=Microsoft Corporation, C=US" }
		}
	}
	function Move-Item {
		param($LiteralPath, $Destination)
		Assert-Equal $state.Signed $true
		Assert-Equal $Destination $PsExecPath
		$state.Moved = $true
	}
	function Resolve-Path { [PSCustomObject]@{ ProviderPath = "resolved-download.exe" } }
	Assert-Equal (Ensure-PsExec) "resolved-download.exe"
	Assert-Equal $state.Moved $true
}
Test-Case "A valid signature from another publisher is rejected" {
	$PsExecPath = "other-publisher.exe"
	function Test-Path { $true }
	function Get-AuthenticodeSignature {
		[PSCustomObject]@{
			Status = "Valid"
			SignerCertificate = [PSCustomObject]@{ Subject = "CN=Other, O=Other Corporation, C=US" }
		}
	}
	$caught = $false
	try { Ensure-PsExec } catch { $caught = $_.Exception.Message -like "*valid Microsoft*" }
	Assert-Equal $caught $true
}
Test-Case "An unelevated caller never starts cleanup" {
	$AsSystemPass = $false
	function Test-IsLocalSystem { $false }
	function Test-IsAdministrator { $false }
	function Invoke-LegacyCleanupPass { throw "Must not clean without elevation" }
	Assert-Equal (Invoke-EntryForTest) 1
}
Test-Case "The SYSTEM flag cannot bypass identity checks" {
	$AsSystemPass = $true
	function Test-IsLocalSystem { $false }
	function Invoke-LegacyCleanupPass { throw "Must not clean with a fake SYSTEM flag" }
	Assert-Equal (Invoke-EntryForTest) 1
}
Test-Case "SYSTEM mode verifies without downloading or relaunching PsExec" {
	$AsSystemPass = $true
	function Test-IsLocalSystem { $true }
	function Invoke-LegacyCleanupPass {}
	function Ensure-PsExec { throw "Must not use PsExec when already SYSTEM" }
	function Get-RemainingLegacyItems { New-Remaining }
	Assert-Equal (Invoke-EntryForTest) 0
}
Test-Case "SYSTEM mode does not return success with leftovers" {
	$AsSystemPass = $true
	function Test-IsLocalSystem { $true }
	function Invoke-LegacyCleanupPass {}
	function Get-RemainingLegacyItems { New-Remaining -Paths "leftover" }
	Assert-Equal (Invoke-EntryForTest) 1
}
Test-Case "ADMIN can explicitly skip the SYSTEM pass" {
	$AsSystemPass = $false
	$SkipSystemPass = $true
	function Test-IsLocalSystem { $false }
	function Test-IsAdministrator { $true }
	function Invoke-LegacyCleanupPass {}
	function Ensure-PsExec { throw "Must respect SkipSystemPass" }
	function Get-RemainingLegacyItems { New-Remaining }
	Assert-Equal (Invoke-EntryForTest) 0
}
foreach ($childCode in @(0, 1, 3010)) {
	Test-Case "ADMIN handles SYSTEM child exit code $childCode" {
		$AsSystemPass = $false
		$SkipSystemPass = $false
		$PsExecPath = "Mock-PsExec"
		$state = @{ ChildCalled = $false }
		function Test-IsLocalSystem { $false }
		function Test-IsAdministrator { $true }
		function Invoke-LegacyCleanupPass { throw "ADMIN must escalate before any cleanup" }
		function Ensure-PsExec { "Mock-PsExec" }
		function Get-RemainingLegacyItems { New-Remaining }
		function Mock-PsExec {
			$state.ChildCalled = $true
			Assert-Equal ($args -contains "-AsSystemPass") $true
			Assert-Equal ($args -contains "-SkipSystemPass") $true
			$global:LASTEXITCODE = $childCode
		}
		Assert-Equal (Invoke-EntryForTest) $childCode
		Assert-Equal $state.ChildCalled $true
	}
}

Test-Case "Failed PsExec launch never falls back to ADMIN cleanup" {
	$AsSystemPass = $false
	$SkipSystemPass = $false
	function Test-IsLocalSystem { $false }
	function Test-IsAdministrator { $true }
	function Invoke-LegacyCleanupPass { throw "Must not fall back to ADMIN cleanup" }
	function Ensure-PsExec { throw "PsExec unavailable" }
	Assert-Equal (Invoke-EntryForTest) 1
}

Write-Host "$script:passed tests passed; script parsed successfully."
