<#
.SYNOPSIS
    Makes every DDEV site on the Linux VM reachable from Windows, and trusts the
    VM's local HTTPS certificate authority.

.DESCRIPTION
    Two rules cover any number of projects, forever. The trick is that
    *.ddev.site is a real public DNS wildcard that already resolves to 127.0.0.1
    on every machine, including this one — Windows is already sending
    anything.ddev.site to its own loopback, there is simply nothing listening
    there. So instead of maintaining a hosts entry per project (the Windows hosts
    file has no wildcard support, so that really would be one line per site),
    this puts a TCP relay on loopback pointing at the VM:

        browser  ->  myproject.ddev.site  ->  127.0.0.1:443  ->  VM:443  ->  traefik

    Because the relay is plain TCP, the Host header and TLS SNI arrive at the
    VM untouched, so DDEV's router sees the real hostname and routes to the right
    project. A new project needs no configuration at all: `ddev start` and it
    works.

    The script also imports the VM's mkcert root CA into the Windows Trusted Root
    store, without which every https://*.ddev.site page shows a certificate
    error that Chromium-based browsers will not let you click through.

.PARAMETER VmHost
    Hostname or IP of the Linux VM. Defaults to the Hyper-V-registered name.

.PARAMETER CaCertPath
    Path to a copy of the VM's rootCA.pem. Get it from the VM with:
        cat "$(mkcert -CAROOT)/rootCA.pem"
    and paste it into a file on Windows, or copy it over the RDP clipboard.
    Omit to skip the certificate step.

.PARAMETER Remove
    Remove the port proxy rules instead of adding them.

.EXAMPLE
    .\Setup-DdevPortProxy.ps1
    Point loopback 80/443 at the VM, resolving it by name.

.EXAMPLE
    .\Setup-DdevPortProxy.ps1 -CaCertPath C:\temp\rootCA.pem
    Same, and also trust the VM's certificate authority.

.NOTES
    MUST be run from an elevated (Administrator) PowerShell.

    Re-run this whenever the VM's IP changes. Hyper-V's Default Switch hands out
    DHCP addresses that can change when Windows reboots, which is why the script
    resolves the name each time rather than hardcoding an address. Give the VM a
    static address if you would rather not think about it.
#>

[CmdletBinding()]
param(
    [string] $VmHost = "$($env:SANDBOX_VM_HOST)",
    [string] $CaCertPath,
    [switch] $Remove
)

$ErrorActionPreference = 'Stop'

if (-not $VmHost) { $VmHost = 'web-dev.mshome.net' }

# --- must be elevated ------------------------------------------------------
$identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "This script must be run from an elevated (Administrator) PowerShell."
}

$ports = @(80, 443)

# --- removal ---------------------------------------------------------------
if ($Remove) {
    foreach ($p in $ports) {
        Write-Host "Removing portproxy for 127.0.0.1:$p ..." -ForegroundColor Cyan
        # Tolerate a rule that is not there.
        cmd /c "netsh interface portproxy delete v4tov4 listenaddress=127.0.0.1 listenport=$p" 2>$null | Out-Null
    }
    Write-Host "Done. Current rules:" -ForegroundColor Green
    cmd /c "netsh interface portproxy show v4tov4"
    return
}

# --- resolve the VM --------------------------------------------------------
Write-Host "Resolving $VmHost ..." -ForegroundColor Cyan
try {
    $vmIp = (Resolve-DnsName -Name $VmHost -Type A -ErrorAction Stop |
             Where-Object { $_.IPAddress } |
             Select-Object -First 1).IPAddress
} catch {
    throw "Could not resolve '$VmHost'. Pass -VmHost with the VM's IP address instead."
}
if (-not $vmIp) { throw "Could not resolve '$VmHost' to an IPv4 address." }
Write-Host "  $VmHost -> $vmIp" -ForegroundColor Green

# --- warn about anything already holding the ports -------------------------
# IIS, Skype and some VPN clients bind 443 and would win over the relay.
foreach ($p in $ports) {
    $inUse = Get-NetTCPConnection -State Listen -LocalPort $p -ErrorAction SilentlyContinue |
             Where-Object { $_.OwningProcess -ne 0 }
    if ($inUse) {
        $procs = $inUse | ForEach-Object {
            (Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue).ProcessName
        } | Sort-Object -Unique
        Write-Warning "Port $p already has a listener: $($procs -join ', '). The relay may not take effect until it is stopped."
    }
}

# --- the two rules ---------------------------------------------------------
foreach ($p in $ports) {
    Write-Host "Pointing 127.0.0.1:$p at ${vmIp}:$p ..." -ForegroundColor Cyan
    # Delete first so re-running after an IP change replaces the rule instead of
    # failing on a duplicate.
    cmd /c "netsh interface portproxy delete v4tov4 listenaddress=127.0.0.1 listenport=$p" 2>$null | Out-Null
    $out = cmd /c "netsh interface portproxy add v4tov4 listenaddress=127.0.0.1 listenport=$p connectaddress=$vmIp connectport=$p"
    if ($LASTEXITCODE -ne 0) { throw "netsh failed for port ${p}: $out" }
}

Write-Host "`nPort proxy rules now in place:" -ForegroundColor Green
cmd /c "netsh interface portproxy show v4tov4"

# --- certificate authority -------------------------------------------------
if ($CaCertPath) {
    if (-not (Test-Path $CaCertPath)) { throw "CA certificate not found: $CaCertPath" }
    Write-Host "`nImporting the VM's root CA into Trusted Root Certification Authorities ..." -ForegroundColor Cyan
    $cert = Import-Certificate -FilePath $CaCertPath -CertStoreLocation Cert:\LocalMachine\Root
    Write-Host "  Imported: $($cert.Subject)" -ForegroundColor Green
    Write-Host "  Thumbprint: $($cert.Thumbprint)"
} else {
    Write-Host "`nSkipped the certificate step (-CaCertPath not given)." -ForegroundColor Yellow
    Write-Host "Without it, https://<project>.ddev.site will show a certificate error"
    Write-Host "that Chromium will not let you click past. To fix it later, copy"
    Write-Host "rootCA.pem off the VM:"
    Write-Host '    cat "$(mkcert -CAROOT)/rootCA.pem"' -ForegroundColor Gray
    Write-Host "and re-run this script with -CaCertPath pointing at it."
}

Write-Host "`nTest it with a project that is running on the VM, for example:" -ForegroundColor Cyan
Write-Host "    https://claude-wordpress-ddev-sandbox.ddev.site" -ForegroundColor Gray
Write-Host "`nIf the VM's IP changes later, just re-run this script." -ForegroundColor Cyan
