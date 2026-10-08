[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
if (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'rocom-capture.exe')) {
    $binaryDir = $PSScriptRoot
} else {
    $repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $binaryDir = Join-Path $repoRoot 'dist/windows-amd64'
}
$adapterExe = Join-Path $binaryDir 'rocom-interfaces.exe'
$captureExe = Join-Path $binaryDir 'rocom-capture.exe'
$script:captureProcess = $null

$form = New-Object System.Windows.Forms.Form
$form.Text = 'rocom-capture 抓包启动器'
$form.ClientSize = New-Object System.Drawing.Size(660, 460)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10)

function Add-Label($text, $x, $y, $width, $height) {
    $label = New-Object System.Windows.Forms.Label
    $label.Text = $text
    $label.SetBounds($x, $y, $width, $height)
    $form.Controls.Add($label)
}

Add-Label '网卡（选择承载游戏流量的网卡）' 20 15 600 25
$adapters = New-Object System.Windows.Forms.ComboBox
$adapters.DropDownStyle = 'DropDownList'
$adapters.DisplayMember = 'Label'
$adapters.DropDownWidth = 950
$adapters.SetBounds(20, 45, 515, 30)
$form.Controls.Add($adapters)
$refresh = New-Object System.Windows.Forms.Button
$refresh.Text = '刷新'
$refresh.SetBounds(545, 43, 95, 32)
$form.Controls.Add($refresh)

Add-Label 'addr（网页监听地址）' 20 85 600 25
$address = New-Object System.Windows.Forms.TextBox
$address.Text = '127.0.0.1:4939'
$address.SetBounds(20, 115, 515, 30)
$form.Controls.Add($address)
$start = New-Object System.Windows.Forms.Button
$start.Text = '开始抓包'
$start.SetBounds(20, 160, 130, 36)
$form.Controls.Add($start)
$status = New-Object System.Windows.Forms.Label
$status.SetBounds(165, 165, 475, 45)
$form.Controls.Add($status)
$openWeb = New-Object System.Windows.Forms.Button
$openWeb.Text = '打开 Web 界面'
$openWeb.SetBounds(20, 212, 620, 32)
$openWeb.Enabled = $false
$form.Controls.Add($openWeb)
$logs = New-Object System.Windows.Forms.TextBox
$logs.Multiline = $true
$logs.ReadOnly = $true
$logs.ScrollBars = 'Vertical'
$logs.SetBounds(20, 255, 620, 165)
$form.Controls.Add($logs)
Add-Label '关闭此界面会停止本次启动的抓包。' 20 432 620 25
$script:streams = @()
$script:webURL = $null

function Set-Running($running) {
    $start.Text = if ($running) { '停止抓包' } else { '开始抓包' }
    $refresh.Enabled = -not $running
    $adapters.Enabled = -not $running
    $address.Enabled = -not $running
    $openWeb.Enabled = $running
}

function Read-Logs {
    foreach ($stream in $script:streams) {
        for ($i = 0; $i -lt 100 -and $null -ne $stream.Pending -and $stream.Pending.IsCompleted; $i++) {
            $line = $stream.Pending.GetAwaiter().GetResult()
            if ($null -eq $line) { $stream.Pending = $null; break }
            # Upstream prepends localhost even when -addr already contains a host.
            if ($script:webURL -and $line -match '^(\d{4}/\d{2}/\d{2} \d{2}:\d{2}:\d{2} Web 界面: )http://\S+$') {
                $line = $Matches[1] + $script:webURL
            }
            if ($logs.TextLength -gt 60000) { $logs.Text = $logs.Text.Substring($logs.TextLength - 30000) }
            $logs.AppendText($line + [Environment]::NewLine)
            $stream.Pending = $stream.Reader.ReadLineAsync()
        }
    }
}

function Stop-Capture {
    if ($script:captureProcess) {
        if (-not $script:captureProcess.HasExited) {
            $script:captureProcess.Kill()
            $script:captureProcess.WaitForExit()
        }
        Read-Logs
        foreach ($stream in $script:streams) { $stream.Reader.Dispose() }
        $script:streams = @()
        $script:captureProcess.Dispose()
        $script:captureProcess = $null
    }
    Set-Running $false
}
$openWeb.Add_Click({
    try { Start-Process $script:webURL } catch { Show-Error $_.Exception.Message }
})

function Show-Error($message) {
    [System.Windows.Forms.MessageBox]::Show($form, $message, '启动器', 'OK', 'Error') | Out-Null
}

function Refresh-Adapters {
    try {
        if (-not (Test-Path -LiteralPath $adapterExe)) {
            throw '缺少网卡工具，请先运行 build-windows.bat。'
        }
        $selectedName = if ($adapters.SelectedItem) { $adapters.SelectedItem.Name } else { $null }
        $info = New-Object System.Diagnostics.ProcessStartInfo
        $info.FileName = $adapterExe
        $info.Arguments = '-json'
        $info.UseShellExecute = $false
        $info.CreateNoWindow = $true
        $info.RedirectStandardOutput = $true
        $info.RedirectStandardError = $true
        $info.StandardOutputEncoding = [Text.Encoding]::UTF8
        $process = [Diagnostics.Process]::Start($info)
        try {
            $outputTask = $process.StandardOutput.ReadToEndAsync()
            $errorTask = $process.StandardError.ReadToEndAsync()
            if (-not $process.WaitForExit(10000)) {
                $process.Kill()
                throw '读取网卡超时，请检查 Npcap。'
            }
            if ($process.ExitCode -ne 0) { throw $errorTask.Result }
            $devices = ConvertFrom-Json -InputObject $outputTask.Result
        } finally { $process.Dispose() }
        $adapters.Items.Clear()
        $systemAdapters = [Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()
        $routeCosts = @{}
        $physicalIndexes = @()
        try {
            $physicalIndexes = @(Get-NetAdapter -Physical -ErrorAction Stop | Where-Object Status -eq 'Up' | ForEach-Object { [int]$_.ifIndex })
        } catch { }
        try {
            $metrics = @{}
            Get-NetIPInterface -AddressFamily IPv4 -ErrorAction Stop | ForEach-Object {
                $metrics[[int]$_.InterfaceIndex] = [int]$_.InterfaceMetric
            }
            Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -PolicyStore ActiveStore -ErrorAction Stop | ForEach-Object {
                $key = [int]$_.InterfaceIndex
                $cost = [long]$_.RouteMetric + $metrics[$key]
                if (-not $routeCosts.ContainsKey($key) -or $cost -lt $routeCosts[$key]) { $routeCosts[$key] = $cost }
            }
        } catch {
            # Network cmdlets may be unavailable; connected interfaces with a gateway are the fallback.
        }
        $bestIndex = -1
        $bestRank = [long]::MaxValue
        foreach ($device in $devices) {
            $friendly = $device.description
            $match = @($systemAdapters | Where-Object { $device.name -eq ('\Device\NPF_' + $_.Id) })
            if ($match.Count -gt 0) { $friendly = $match[0].Name }
            if ($device.name -eq '\Device\NPF_Loopback') { $friendly = '本机回环' }
            if (-not $friendly) { $friendly = $device.name }
            $ips = @($device.addresses | Where-Object { $_ -match '^\d+\.' })
            if ($ips.Count -eq 0) { $ips = @($device.addresses) }
            $label = if ($ips.Count) { '{0}（{1}）' -f $friendly, ($ips -join ', ') } else { '{0}（无 IP）' -f $friendly }
            $index = $adapters.Items.Add([pscustomobject]@{ Label = $label; Name = $device.name })
            if ($device.name -eq $selectedName) { $adapters.SelectedIndex = $index }
            if ($match.Count -gt 0 -and $match[0].OperationalStatus -eq 'Up' -and
                $match[0].NetworkInterfaceType -notin @('Loopback', 'Tunnel')) {
                $properties = $match[0].GetIPProperties()
                $validIPv4 = @($device.addresses | Where-Object { $_ -match '^\d+\.' -and $_ -notmatch '^(169\.254\.|127\.|0\.)' })
                if ($validIPv4.Count -gt 0) {
                    $rank = [long]20000000000
                    if ($properties.GatewayAddresses.Count -gt 0) { $rank = [long]10000000000 }
                    $ipv4 = $properties.GetIPv4Properties()
                    if ($ipv4 -and $routeCosts.ContainsKey([int]$ipv4.Index)) { $rank = $routeCosts[[int]$ipv4.Index] }
                    if ($physicalIndexes.Count -gt 0 -and $ipv4 -and [int]$ipv4.Index -notin $physicalIndexes) {
                        $rank += [long]30000000000
                    }
                    if ($rank -lt $bestRank) { $bestRank = $rank; $bestIndex = $index }
                }
            }
        }
        if ($adapters.SelectedIndex -lt 0 -and $bestIndex -ge 0) { $adapters.SelectedIndex = $bestIndex }
        $status.Text = '请选择网卡，再开始抓包。'
        if ($adapters.Items.Count -eq 0) { throw '未发现网卡，请检查 Npcap 安装与权限。' }
    } catch {
        $status.Text = '读取网卡失败。'
        Show-Error $_.Exception.Message
    }
}

$refresh.Add_Click({ Refresh-Adapters })
$start.Add_Click({
    try {
        if ($script:captureProcess) {
            Stop-Capture
            $status.Text = '已停止抓包。'
            return
        }
        if (-not $adapters.SelectedItem) { throw '请先选择网卡。' }
        if (-not (Test-Path -LiteralPath $captureExe)) { throw '缺少抓包程序，请先运行 build-windows.bat。' }
        $listen = $address.Text.Trim()
        # Accept host:port, :port, or [IPv6]:port; reject shell/argument delimiters.
        if ($listen -notmatch '^(?:[a-zA-Z0-9._-]*|\[[0-9a-fA-F:.%]+\]):([0-9]{1,5})$') {
            throw 'addr 格式应为 主机:端口，例如 127.0.0.1:4939 或 [::1]:4939。'
        }
        $port = [int]$Matches[1]
        if ($port -lt 1 -or $port -gt 65535) { throw '端口必须在 1 到 65535 之间。' }
        $deviceName = [string]$adapters.SelectedItem.Name
        if ($deviceName -match '["\r\n]') { throw '网卡名称格式异常。' }
        $arguments = '-iface "{0}" -addr "{1}"' -f $deviceName, $listen
        $info = New-Object Diagnostics.ProcessStartInfo
        $info.FileName = $captureExe
        $info.Arguments = $arguments
        $info.WorkingDirectory = $binaryDir
        $info.UseShellExecute = $false
        $info.CreateNoWindow = $true
        $info.RedirectStandardOutput = $true
        $info.RedirectStandardError = $true
        $info.StandardOutputEncoding = [Text.Encoding]::UTF8
        $info.StandardErrorEncoding = [Text.Encoding]::UTF8
        $logs.Clear()
        $script:captureProcess = [Diagnostics.Process]::Start($info)
        $script:streams = @(
            @{ Reader = $script:captureProcess.StandardOutput; Pending = $script:captureProcess.StandardOutput.ReadLineAsync() },
            @{ Reader = $script:captureProcess.StandardError; Pending = $script:captureProcess.StandardError.ReadLineAsync() }
        )
        $browserAddress = $listen -replace '^(0\.0\.0\.0|\[::\]|):', '127.0.0.1:'
        $script:webURL = 'http://' + $browserAddress
        Set-Running $true
        $status.Text = '已启动，Web 地址：' + $script:webURL
    } catch { Show-Error $_.Exception.Message }
})

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 500
$timer.Add_Tick({
    Read-Logs
    if ($script:captureProcess -and $script:captureProcess.HasExited) {
        $status.Text = '抓包进程已退出。退出码：' + $script:captureProcess.ExitCode
        Stop-Capture
    }
})
$form.Add_Shown({ Refresh-Adapters; $timer.Start() })
try { $form.ShowDialog() | Out-Null } finally {
    $timer.Dispose()
    Stop-Capture
    $form.Dispose()
}
