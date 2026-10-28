#requires -Version 5.1
[CmdletBinding()]
param(
	[string]$PsExecUrl = "https://live.sysinternals.com/PsExec.exe",
	[string]$PsExecPath = "$env:TEMP\PsExec.exe",
	[switch]$SkipSystemPass,
	[switch]$AsSystemPass,
	[ValidateRange(1, 300)]
	[int]$TimeoutSeconds = 30
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
# Native tools use documented exit codes, including nonzero idempotent results. 
$PSNativeCommandUseErrorActionPreference = $false
$legacyServiceNames = @("WinTelemetrySvc", "MultiplatformRemoteBroker")
$legacyTaskNames = @("WinTelemetrySvcMaintenance")
$script:cleanupErrors = New-Object 'System.Collections.Generic.List[string]'
$script:targetPaths = @()
$script:serviceExecutables = @()
$script:deleteRequested = @()
$script:cleanupScriptPath = $PSCommandPath

function Write-Step {
	param([string]$Message)
	Write-Host "[legacy-cleanup] $Message"
}

function Invoke-CleanupAction {
	param([string]$Label, [scriptblock]$Action)
	try {
		& $Action
	}
	catch {
		$message = "${Label}: $($_.Exception.Message)"
		$script:cleanupErrors.Add($message)
		Write-Warning $message
	}
}

function Test-IsLocalSystem {
	$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
	try {
		return $identity.User.Value -eq "S-1-5-18"
	}
	finally {
		$identity.Dispose()
	}
}

function Test-IsAdministrator {
	$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
	try {
		$principal = New-Object Security.Principal.WindowsPrincipal($identity)
		return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
	}
	finally {
		$identity.Dispose()
	}
}

function Get-LegacyPaths {
	$localRoots = New-Object 'System.Collections.Generic.List[string]'
	foreach ($root in @(
		$env:LOCALAPPDATA
		"$env:WINDIR\System32\config\systemprofile\AppData\Local"
		"$env:WINDIR\SysWOW64\config\systemprofile\AppData\Local"
		"$env:WINDIR\ServiceProfiles\LocalService\AppData\Local"
		"$env:WINDIR\ServiceProfiles\NetworkService\AppData\Local"
	)) {
		if ($root) {
			$localRoots.Add($root)
		}
	}
	Invoke-CleanupAction -Label "Discovering registered profiles" -Action {
		$profileKeys = @(Get-ChildItem -LiteralPath "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList")
		foreach ($key in $profileKeys) {
			$profile = Get-ItemProperty -LiteralPath $key.PSPath
			if ($profile.PSObject.Properties["ProfileImagePath"] -and $profile.ProfileImagePath) {
				$profilePath = [Environment]::ExpandEnvironmentVariables($profile.ProfileImagePath)
				$localRoots.Add((Join-Path $profilePath "AppData\Local"))
			}
		}
	}
	Invoke-CleanupAction -Label "Discovering unregistered profiles" -Action {
		$usersPath = Join-Path $env:SystemDrive "Users"
		if (Test-Path -LiteralPath $usersPath) {
			foreach ($profile in @(Get-ChildItem -LiteralPath $usersPath -Directory -Force)) {
				# Compatibility junctions such as "All Users" must not be traversed.
				if (-not ($profile.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
					$localRoots.Add((Join-Path $profile.FullName "AppData\Local"))
				}
			}
		}
	}
	foreach ($root in @($localRoots | Sort-Object -Unique)) {
		Invoke-CleanupAction -Label "Inspecting $root" -Action {
			if (Test-Path -LiteralPath $root) {
				Get-ChildItem -LiteralPath $root -Force |
					Where-Object { $_.Name -like "TelemetryUpdate*" } |
					Select-Object -ExpandProperty FullName
			}
		}
	}
}

function Get-LegacyServices {
	foreach ($name in $legacyServiceNames) {
		$services = @(Get-CimInstance -ClassName Win32_Service -Filter "Name='$name'")
		if ($services.Count -gt 0) {
			$services
		}
		elseif (Test-Path -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Services\$name") {
			# SCM/CIM can stop enumerating a service before its key disappears.
			[PSCustomObject]@{ Name = $name; State = "Registry entry remains" }
		}
	}
}

function Get-LegacyTasks {
	# Enumerate all task folders, not just the Task Scheduler root.
	Get-ScheduledTask | Where-Object { $_.TaskName -in $legacyTaskNames }
}

function Get-ServiceExecutablePath {
	param([string]$PathName)
	if (-not $PathName) {
		return $null
	}
	$trimmed = $PathName.Trim()
	if ($trimmed.StartsWith('"')) {
		# A quoted image path ends at the closing quote, before any arguments.
		$end = $trimmed.IndexOf('"', 1)
		if ($end -gt 1) {
			return $trimmed.Substring(1, $end - 1)
		}
		return $null
	}
	# An unquoted image path ends at its ".exe" token, before any arguments.
	$match = [regex]::Match($trimmed, '^(.*?\.exe)(?:\s|$)', 'IgnoreCase')
	if ($match.Success) {
		return $match.Groups[1].Value
	}
	return ($trimmed -split '\s+', 2)[0]
}

function Get-LegacyServiceExecutablePaths {
	$paths = New-Object 'System.Collections.Generic.List[string]'
	foreach ($name in $legacyServiceNames) {
		Invoke-CleanupAction -Label "Inspecting service image for $name" -Action {
			$svc = Get-CimInstance -ClassName Win32_Service -Filter "Name='$name'"
			if ($svc -and $svc.PathName) {
				$exe = Get-ServiceExecutablePath -PathName $svc.PathName
				# Never target shared service hosts for termination.
				$leaf = if ($exe) { ($exe -split '[\\/]')[-1] } else { $null }
				if ($exe -and $leaf -notin @("svchost.exe", "dllhost.exe", "rundll32.exe")) {
					$paths.Add($exe)
				}
			}
		}
	}
	$paths | Sort-Object -Unique
}

function Get-LegacyProcesses {
	foreach ($process in @(Get-CimInstance -ClassName Win32_Process)) {
		$exe = $process.ExecutablePath
		if (-not $exe) {
			if ($process.Name -eq "TelemetryMainUpdate.exe") {
				throw "Cannot identify executable path for TelemetryMainUpdate.exe PID $($process.ProcessId)."
			}
			continue
		}
		$matched = $false
		foreach ($path in $script:targetPaths) {
			$prefix = $path.TrimEnd('\') + '\'
			if ($exe.Equals($path, [StringComparison]::OrdinalIgnoreCase) -or
				$exe.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
				$matched = $true
				break
			}
		}
		if (-not $matched) {
			foreach ($serviceExe in $script:serviceExecutables) {
				if ($exe.Equals($serviceExe, [StringComparison]::OrdinalIgnoreCase)) {
					$matched = $true
					break
				}
			}
		}
		if ($matched) {
			$process
		}
	}
}

function Stop-LegacyProcesses {
	foreach ($process in @(Get-LegacyProcesses)) {
		Invoke-CleanupAction -Label "Stopping PID $($process.ProcessId)" -Action {
			# Re-query before terminating to reduce the risk of killing a reused PID.
			$current = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId=$($process.ProcessId)"
			if (-not $current) {
				return
			}
			if ($current.CreationDate -ne $process.CreationDate -or $current.ExecutablePath -ne $process.ExecutablePath) {
				throw "PID $($process.ProcessId) changed identity; refusing to terminate it."
			}
			$result = Invoke-CimMethod -InputObject $current -MethodName Terminate -Arguments @{ Reason = [uint32]0 }
			if ($result.ReturnValue -ne 0) {
				throw "Terminate PID $($process.ProcessId) returned $($result.ReturnValue)."
			}
			$timer = [Diagnostics.Stopwatch]::StartNew()
			do {
				$current = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId=$($process.ProcessId)"
				if (-not $current -or $current.CreationDate -ne $process.CreationDate) {
					break
				}
				if ($timer.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
					throw "Timed out waiting for PID $($process.ProcessId) to exit."
				}
				Start-Sleep -Milliseconds 200
			} while ($true)
			Write-Step "Stopped legacy PID $($process.ProcessId)"
		}
	}
}

function Remove-LegacyTasks {
	foreach ($task in @(Get-LegacyTasks)) {
		$label = "Task $($task.TaskPath)$($task.TaskName)"
		Invoke-CleanupAction -Label "Disabling $label" -Action {
			Disable-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath | Out-Null
		}
		Invoke-CleanupAction -Label "Stopping $label" -Action {
			try {
				Stop-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath
			}
			catch {
				$stopError = $_
				$current = @(Get-LegacyTasks | Where-Object {
					$_.TaskName -eq $task.TaskName -and $_.TaskPath -eq $task.TaskPath
				})
				if (@($current | Where-Object { $_.State -notin @("Ready", "Disabled") }).Count -gt 0) {
					throw $stopError
				}
				Write-Warning "$label is no longer running; stop reported: $($stopError.Exception.Message)"
			}
		}
		Invoke-CleanupAction -Label "Deleting $label" -Action {
			Unregister-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath -Confirm:$false
		}
	}
}

function Remove-LegacyServiceKey {
	param([string]$Name)
	$keyPath = "HKLM:\SYSTEM\CurrentControlSet\Services\$Name"
	if (-not (Test-Path -LiteralPath $keyPath)) {
		return $false
	}
	# A hardened key denies writes until ownership and control are reclaimed.
	$administrators = New-Object Security.Principal.SecurityIdentifier "S-1-5-32-544"
	$acl = Get-Acl -LiteralPath $keyPath
	$acl.SetOwner($administrators)
	Set-Acl -LiteralPath $keyPath -AclObject $acl
	$acl = Get-Acl -LiteralPath $keyPath
	$rule = New-Object Security.AccessControl.RegistryAccessRule(
		$administrators, "FullControl", "ContainerInherit", "None", "Allow")
	$acl.AddAccessRule($rule)
	Set-Acl -LiteralPath $keyPath -AclObject $acl
	Remove-Item -LiteralPath $keyPath -Recurse -Force
	if (Test-Path -LiteralPath $keyPath) {
		throw "Service registry key still present after removal."
	}
	return $true
}

function Remove-LegacyServices {
	foreach ($name in $legacyServiceNames) {
		Invoke-CleanupAction -Label "Service $name" -Action {
			$svc = Invoke-CleanupAction -Label "Inspecting service $name" -Action {
				Get-CimInstance -ClassName Win32_Service -Filter "Name='$name'"
			}
			# Prevent service recovery or other triggers from starting it again.
			if ($svc) {
				Invoke-CleanupAction -Label "Disabling service $name" -Action {
					$result = Invoke-CimMethod -InputObject $svc -MethodName ChangeStartMode -Arguments @{ StartMode = "Disabled" }
					if ($result.ReturnValue -ne 0) {
						Write-Warning "Disabling $name returned $($result.ReturnValue); attempting deletion anyway."
					}
				}
			}
			if ($svc -and $svc.State -ne "Stopped") {
				Invoke-CleanupAction -Label "Stopping service $name" -Action {
					$result = Invoke-CimMethod -InputObject $svc -MethodName StopService
					if ($result.ReturnValue -notin @(0, 5, 6, 10)) {
						Write-Warning "Stopping $name returned $($result.ReturnValue); attempting deletion anyway."
					}
					$timer = [Diagnostics.Stopwatch]::StartNew()
					do {
						$svc = Get-CimInstance -ClassName Win32_Service -Filter "Name='$name'"
						if (-not $svc -or $svc.State -eq "Stopped") {
							break
						}
						Start-Sleep -Milliseconds 250
					} while ($timer.Elapsed.TotalSeconds -lt $TimeoutSeconds)
					if ($svc -and $svc.State -ne "Stopped") {
						Write-Warning "$name has not stopped; deletion may require a restart."
					}
				}
			}
			$output = & "$env:WINDIR\System32\sc.exe" delete $name 2>&1
			$code = $LASTEXITCODE
			if ($code -eq 5) {
				# A hardened service DACL can deny DELETE even to SYSTEM; reset it and retry.
				Write-Step "Resetting security descriptor for $name after access denied"
				$sdDacl = "D:(A;;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;SY)(A;;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;BA)(A;;CCLCSWLOCRRC;;;IU)(A;;CCLCSWLOCRRC;;;SU)"
				$sdOutput = & "$env:WINDIR\System32\sc.exe" sdset $name $sdDacl 2>&1
				if ($LASTEXITCODE -ne 0) {
					Write-Warning "sc.exe sdset returned $($LASTEXITCODE): $($sdOutput -join ' ')"
				}
				$output = & "$env:WINDIR\System32\sc.exe" delete $name 2>&1
				$code = $LASTEXITCODE
			}
			if ($code -notin @(0, 1060, 1072)) {
				# SCM still refuses; remove the hardened service registry key directly.
				Write-Step "Falling back to registry removal for $name"
				if (Remove-LegacyServiceKey -Name $name) {
					$script:deleteRequested += $name
					return
				}
				throw "sc.exe delete returned ${code}: $($output -join ' ')"
			}
			if ($code -ne 1060) {
				$script:deleteRequested += $name
			}
		}
	}
}

function Remove-LegacyFiles {
	foreach ($path in $script:targetPaths) {
		Invoke-CleanupAction -Label "Path $path" -Action {
			if (-not (Test-Path -LiteralPath $path)) {
				return
			}
			$item = Get-Item -LiteralPath $path -Force
			if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
				throw "Refusing recursive deletion of a reparse point."
			}
			if ($item.PSIsContainer) {
				# Refuse links before recursing, rather than following their targets.
				$pending = New-Object 'System.Collections.Generic.Queue[string]'
				$pending.Enqueue($path)
				while ($pending.Count -gt 0) {
					foreach ($child in @(Get-ChildItem -LiteralPath $pending.Dequeue() -Force)) {
						if ($child.Attributes -band [IO.FileAttributes]::ReparsePoint) {
							throw "Reparse point inside deployment: $($child.FullName)"
						}
						if ($child.PSIsContainer) {
							$pending.Enqueue($child.FullName)
						}
					}
				}
			}
			Remove-Item -LiteralPath $path -Recurse -Force
			if (Test-Path -LiteralPath $path) {
				throw "Path still exists after removal."
			}
			Write-Step "Removed: $path"
		}
	}
}

function Get-RemainingLegacyItems {
	$services = @(Get-LegacyServices)
	$tasks = @(Get-LegacyTasks)
	$script:targetPaths = @(@($script:targetPaths) + @(Get-LegacyPaths) | Sort-Object -Unique)
	$paths = @($script:targetPaths |
		Where-Object { Test-Path -LiteralPath $_ })
	$processes = @(Get-LegacyProcesses)
	[PSCustomObject]@{
		Services = $services
		Tasks = $tasks
		Paths = $paths
		Processes = $processes
	}
}

function Get-CleanupExitCode {
	$remaining = Get-RemainingLegacyItems
	foreach ($svc in $remaining.Services) {
		Write-Warning "Remaining service: $($svc.Name), state: $($svc.State)"
	}
	foreach ($task in $remaining.Tasks) {
		Write-Warning "Remaining task: $($task.TaskPath)$($task.TaskName)"
	}
	foreach ($path in $remaining.Paths) {
		Write-Warning "Remaining path: $path"
	}
	foreach ($process in $remaining.Processes) {
		Write-Warning "Remaining process: $($process.ProcessId)"
	}
	if ($script:cleanupErrors.Count -gt 0) {
		Write-Warning "Cleanup had $($script:cleanupErrors.Count) error(s); see warnings above."
		return 1
	}
	if ($remaining.Tasks.Count -gt 0 -or $remaining.Paths.Count -gt 0 -or $remaining.Processes.Count -gt 0) {
		return 1
	}
	if ($remaining.Services.Count -gt 0) {
		$notRequested = @($remaining.Services | Where-Object { $_.Name -notin $script:deleteRequested })
		if ($notRequested.Count -eq 0) {
			Write-Warning "Service deletion is pending. Restart Windows and run cleanup again to verify."
			return 3010
		}
		return 1
	}
	Write-Step "Verified: no targeted services, tasks, processes or files remain."
	return 0
}

function Ensure-PsExec {
	$candidate = $PsExecPath
	$downloadPath = $null
	try {
		if (-not (Test-Path -LiteralPath $PsExecPath)) {
			if (([uri]$PsExecUrl).Scheme -ne "https") {
				throw "PsExec download requires HTTPS."
			}
			$downloadPath = "$PsExecPath.$([Guid]::NewGuid().ToString('N')).download.exe"
			$candidate = $downloadPath
			Write-Step "Downloading PsExec"
			Invoke-WebRequest -Uri $PsExecUrl -OutFile $downloadPath -UseBasicParsing -TimeoutSec $TimeoutSeconds
		}
		$signature = Get-AuthenticodeSignature -LiteralPath $candidate
		if ($signature.Status -ne "Valid" -or
			$signature.SignerCertificate.Subject -notmatch '(^|,\s*)O=Microsoft Corporation(,|$)') {
			throw "PsExec must have a valid Microsoft Authenticode signature: $candidate"
		}
		if ($downloadPath) {
			Move-Item -LiteralPath $downloadPath -Destination $PsExecPath
		}
		(Resolve-Path -LiteralPath $PsExecPath).ProviderPath
	}
	finally {
		if ($downloadPath -and (Test-Path -LiteralPath $downloadPath)) {
			Remove-Item -LiteralPath $downloadPath -Force
		}
	}
}

function Invoke-LegacyCleanupPass {
	$script:targetPaths = @(Get-LegacyPaths | Sort-Object -Unique)
	# Capture service image paths before deletion so stragglers can still be killed.
	$script:serviceExecutables = @(Get-LegacyServiceExecutablePaths)
	Invoke-CleanupAction -Label "Removing scheduled tasks" -Action { Remove-LegacyTasks }
	Invoke-CleanupAction -Label "Removing services" -Action { Remove-LegacyServices }
	Invoke-CleanupAction -Label "Stopping deployment processes" -Action { Stop-LegacyProcesses }
	Remove-LegacyFiles
	# Release the stopped service and wait for SCM's deferred deletion.
	Invoke-CleanupAction -Label "Waiting for service deletion" -Action {
		$timer = [Diagnostics.Stopwatch]::StartNew()
		while (@(Get-LegacyServices).Count -gt 0 -and $timer.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
			Start-Sleep -Milliseconds 250
		}
	}
}

try {
	if ($env:OS -ne "Windows_NT") {
		throw "This script requires Windows."
	}
	if (-not [Environment]::Is64BitProcess -and [Environment]::Is64BitOperatingSystem) {
		throw "Use 64-bit PowerShell to inspect the native service and profile locations."
	}
	$isLocalSystem = Test-IsLocalSystem
	if ($AsSystemPass -and -not $isLocalSystem) {
		throw "-AsSystemPass requires an actual LocalSystem token."
	}
	if (-not $isLocalSystem -and -not (Test-IsAdministrator)) {
		throw "Run in an elevated Administrator PowerShell or as LocalSystem."
	}
	if (-not $isLocalSystem -and -not $SkipSystemPass) {
		if (-not $script:cleanupScriptPath) {
			throw "Save this script to disk before using the SYSTEM pass."
		}
		$executable = Ensure-PsExec
		$powerShell = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
		Write-Step "Starting cleanup via PsExec as LocalSystem"
		& $executable -accepteula -nobanner -s $powerShell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "`"$script:cleanupScriptPath`"" -AsSystemPass -SkipSystemPass -TimeoutSeconds $TimeoutSeconds
		$childCode = $LASTEXITCODE
		if ($childCode -notin @(0, 3010)) {
			throw "PsExec/SYSTEM cleanup returned $childCode."
		}
		exit $childCode
	}
	Write-Step "Starting cleanup (LocalSystem=$isLocalSystem)"
	Invoke-LegacyCleanupPass
	exit (Get-CleanupExitCode)
}
catch {
	Write-Warning "Cleanup could not be completed or verified: $($_.Exception.Message)"
	exit 1
}
