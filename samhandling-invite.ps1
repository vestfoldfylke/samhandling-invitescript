<#
Hente miljøvariabler
Lage app registrering i egen tenant (i hvert fylke)
    - Group Member ReadAll
    - User ReadAll
    - lage secret
    - Grante admin consent

Koble til MgGraph som service principal med client secret
    - Connect-MgGraph -ClientId $clientId -TenantId $tenantId -ClientSecret $clientSecret
For hver entra-gruppe som skal over til tilsvarende Samhandling-gruppe,
    - Hente medlemmer i Entra-gruppen (kilden)
    - Hente Samhandling-gruppen
    - Send en invite til medlemmer som ikke er i Entra i Samhandling og legg til medlemmer i Samhandling-gruppen
    - Meld ut medlemmer som ikke lenger skal være medlem (mangler i Entra-gruppen fra kilden)
Lag en rapport på resultatet (konsoll og logg)

#>
# Importer miljøvariabler fra env.ps1
$envFilePath = "./env.ps1"
if (Test-Path $envFilePath) {
    try {
        . $envFilePath
        Write-Host -Message "Miljøvariabler lastet fra $envFilePath."
    } catch {
        Write-Error -Message "Feil ved lasting av miljøfilen $envFilePath : $_"
        exit 1
    }
} else {
    Write-Error -Message "Miljøfilen $envFilePath ble ikke funnet."
    exit 1
}
Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
Import-Module Microsoft.Graph.Groups -ErrorAction Stop

# Valider at alle nødvendige miljøvariabler er satt
$requiredEnvVars = @("clientId", "tenantId", "clientSecret", "groupMapping", "logDirectory")
foreach ($envVar in $requiredEnvVars) {
    if (-not (Get-Variable -Name $envVar -ErrorAction SilentlyContinue)) {
        Write-Error "Miljøvariabelen $envVar er ikke satt."
        exit 1
    }
}

# Opprett loggkatalog hvis den ikke eksisterer
if (-not (Test-Path $logDirectory)) {
    try {
        New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
    } catch {
        Write-Error "Kunne ikke opprette loggkatalogen $logDirectory : $_"
        exit 1
    }
}

# Sett loggfilnavn basert på måned
$logFileName = "log_$(Get-Date -Format 'yyyy-MM').log"
$logFilePath = Join-Path -Path $logDirectory -ChildPath $logFileName

# Funksjon for å logge meldinger
function Write-Log {
    param (
        [string]$Message,
        [string]$Level = "INFO"
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "[$timestamp] [$Level] $Message"
    
    # Logg til fil
    Add-Content -Path $logFilePath -Value $logEntry

    # Logg til konsoll
    if ($Level -eq "ERROR") {
        Write-Host $logEntry -ForegroundColor Red
    } elseif ($Level -eq "WARN") {
        Write-Host $logEntry -ForegroundColor Yellow
    } else {
        Write-Host $logEntry -ForegroundColor Green
    }
}

# Eksempel på bruk av logging
Write-Log -Message "Starter scriptet." -Level "INFO"
#

# Debug: Skriv ut $groupMapping for å bekrefte
try {
    Write-Log -Message "Starter å skrive ut gruppemapping." -Level "INFO"
    $groupMapping.GetEnumerator() | ForEach-Object { Write-Log -Message "$($_.Key) = $($_.Value)" -Level "DEBUG" }
} catch {
    Write-Log -Message "Feil ved lesing av gruppemapping: $_" -Level "ERROR"
    exit 1
}

# Koble til MgGraph som service principal med client secret
try {
    $credential = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList $clientId, $clientSecret
    Write-Log -Message "Prøver å koble til Microsoft Graph med ClientId: $clientId og TenantId: $tenantId." -Level "INFO"
    Connect-MgGraph -TenantId $tenantId -Credential $credential
    Write-Log -Message "Tilkobling til Microsoft Graph vellykket." -Level "INFO"
} catch {
    Write-Log -Message "Feil ved tilkobling til Microsoft Graph: $_" -Level "ERROR"
    exit 1
}

# Funksjon for å hente medlemmer i en gruppe
function Get-GroupMembers {
    param (
        [string]$GroupName
    )
    try {
        # Hent gruppe basert på display name
        $group = Get-MgGroup -Filter "DisplayName eq '$GroupName'" -All
        if (-not $group) {
            Write-Log -Message "Fant ingen gruppe med display name $GroupName." -Level "ERROR"
            exit 1
        }

        # Bruk gruppe-ID for å hente medlemmer
        $groupId = $group.Id
        Write-Log -Message "Henter medlemmer for gruppe $GroupName." -Level "INFO"
        Get-MgGroupMemberAsUser -GroupId $groupId -All
        
    } catch {
        Write-Log -Message "Feil ved henting av medlemmer for gruppe $GroupName : $_" -Level "ERROR"
        exit 1
    }
}

# Funksjon for å sende invitasjon og legge til medlemmer
function Sync-GroupMembers {
    param (
        [string]$SourceGroupName,
        [string]$TargetGroupName
    )

    try {
        Write-Log -Message "Starter synkronisering fra kildegruppe $SourceGroupName til målgruppe $TargetGroupName." -Level "INFO"

        # Hente medlemmer fra kildegruppen
        $sourceMembers = Get-GroupMembers -GroupName $SourceGroupName
        # Skriv ut medlemmer fra kildegruppen på en estetisk måte
        Write-Log -Message "Medlemmer i kildegruppen $SourceGroupName :" -Level "INFO"
        foreach ($member in $sourceMembers) {
            $memberInfo = @"
            ------------------------------
            Display Name : $($member.DisplayName)
            User Principal Name : $($member.UserPrincipalName)
            ID : $($member.Id)
            ------------------------------
"@
            Write-Host $memberInfo -ForegroundColor Cyan
        }
        # Hente medlemmer fra målgruppen
        # $targetMembers = Get-GroupMembers -GroupName $TargetGroupName

        # Finn medlemmer som mangler i målgruppen
        # $membersToAdd = $sourceMembers | Where-Object { $_.Id -notin $targetMembers.Id }
<#
        # Legg til manglende medlemmer
        foreach ($member in $membersToAdd) {
            try {
                Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/groups/$($targetMembers.Id)/members/\$ref" -Headers @{
                    Authorization = "Bearer $(Get-MgGraphAccessToken)"
                    "Content-Type" = "application/json"
                } -Method Post -Body (@{ "@odata.id" = "https://graph.microsoft.com/v1.0/directoryObjects/$($member.Id)" } | ConvertTo-Json -Depth 1)
                Write-Log -Message "La til medlem $($member.DisplayName) i gruppe $TargetGroupName." -Level "INFO"
            } catch {
                Write-Log -Message "Feil ved legging til medlem $($member.DisplayName) i gruppe $TargetGroupName : $_" -Level "ERROR"
            }
        }

        # Finn medlemmer som skal fjernes fra målgruppen
        $membersToRemove = $targetMembers | Where-Object { $_.Id -notin $sourceMembers.Id }

        # Fjern medlemmer som ikke lenger skal være medlem
        foreach ($member in $membersToRemove) {
            try {
                Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/groups/$($targetMembers.Id)/members/$($member.Id)/\$ref" -Headers @{
                    Authorization = "Bearer $(Get-MgGraphAccessToken)"
                    "Content-Type" = "application/json"
                } -Method Delete
                Write-Log -Message "Fjernet medlem $($member.DisplayName) fra gruppe $TargetGroupName." -Level "INFO"
            } catch {
                Write-Log -Message "Feil ved fjerning av medlem $($member.DisplayName) fra gruppe $TargetGroupName : $_" -Level "ERROR"
            }
        }
        #>
    } catch {
        Write-Log -Message "Feil under synkronisering av grupper $SourceGroupName til $TargetGroupName : $_" -Level "ERROR"
    }
}

# Hovedlogikk

try {
    Write-Log -Message "Starter synkronisering av grupper." -Level "INFO"

    # Iterer gjennom mappingen og synkroniser grupper
    foreach ($targetGroupName in $groupMapping.Keys) {
        $sourceGroupName = $groupMapping[$targetGroupName]
        Sync-GroupMembers -SourceGroupName $sourceGroupName -TargetGroupName $targetGroupName
    }

    Write-Log -Message "Synkronisering fullført." -Level "INFO"
} catch {
    Write-Log -Message "En uventet feil oppstod under synkronisering: $_" -Level "ERROR"
}