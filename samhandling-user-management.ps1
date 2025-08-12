# Importer miljøvariabler fra env.ps1
$envFilePath = "./env.ps1"
$apiUrl = "https://user.samhandling.org/api"

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
$requiredEnvVars = @("CLIENT_ID", "TENANT_ID", "CLIENT_SECRET", "GROUP_MAPPING", "LOG_DIRECTORY", "FUNCTION_KEY", "COUNTY_KEY")
foreach ($envVar in $requiredEnvVars) {
    if (-not (Get-Variable -Name $envVar -ErrorAction SilentlyContinue)) {
        Write-Error "Miljøvariabelen $envVar er ikke satt."
        exit 1
    }
}

# Opprett loggkatalog hvis den ikke eksisterer
if (-not (Test-Path $LOG_DIRECTORY)) {
    try {
        New-Item -ItemType Directory -Path $LOG_DIRECTORY -Force | Out-Null
    } catch {
        Write-Error "Kunne ikke opprette loggkatalogen $LOG_DIRECTORY : $_"
        exit 1
    }
}

# Sett loggfilnavn basert på måned
$logFileName = "log_$(Get-Date -Format 'yyyy-MM').log"
$logFilePath = Join-Path -Path $LOG_DIRECTORY -ChildPath $logFileName

# Funksjon for å logge meldinger
function Write-Log {
    param (
        [string]$Message,
        [string]$Level = "INFO"
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "[$timestamp] [$Level] $Message"
    
    # Logg til fil
    Add-Content -Path $logFilePath -Value $logEntry -Encoding BigEndianUnicode

    # Logg til konsoll
    if ($Level -eq "ERROR") {
        Write-Host $logEntry -ForegroundColor Red
    } elseif ($Level -eq "WARN") {
        Write-Host $logEntry -ForegroundColor Yellow
    } else {
        Write-Host $logEntry -ForegroundColor Green
    }
}

Write-Log -Message "Starter scriptet." -Level "INFO"

# Debug: Skriv ut $groupMapping for å bekrefte
try {
    Write-Log -Message "Skriver ut gruppemapping." -Level "INFO"
    $GROUP_MAPPING.GetEnumerator() | ForEach-Object { Write-Log -Message "$($_.Key) = $($_.Value)" -Level "DEBUG" }
} catch {
    Write-Log -Message "Feil ved lesing av gruppemapping: $_" -Level "ERROR"
    exit 1
}

# Koble til MgGraph som service principal med client secret
try {
    $credential = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList $CLIENT_ID, $CLIENT_SECRET
    Write-Log -Message "Prøver å koble til Microsoft Graph med ClientId: $CLIENT_ID og TenantId: $TENANT_ID." -Level "INFO"
    Connect-MgGraph -TenantId $TENANT_ID -Credential $credential
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
        Get-MgGroupMemberAsUser -GroupId $groupId -All -Property "DisplayName,UserPrincipalName,Id,Mail,AccountEnabled"
        
    } catch {
        Write-Log -Message "Feil ved henting av medlemmer for gruppe $GroupName : $_" -Level "ERROR"
        exit 1
    }
}
function Get-TargetGroupMembers {
    param (
        [string]$GroupName
    )
    try {
        $targetMembers = Invoke-RestMethod -Uri "$($apiUrl)/members/$($GroupName)" -Headers @{
            "X-Functions-Key" = $FUNCTION_KEY
            "X-County-Key" = $COUNTY_KEY
            "Content-Type" = "application/json"
        } -Method Get
        Write-Log -Message "Fant $($targetMembers.Count) i gruppe $GroupName." -Level "INFO"
        return $targetMembers
    } catch {
        Write-Log -Message "Feil ved henting av medlemmer fra gruppe $GroupName : $_" -Level "ERROR"
    } 
} 
# Funksjon for å legge til medlemmer
function Sync-GroupMembers {
    param (
        [string]$SourceGroupName,
        [string]$TargetGroupName
    )

    try {
        Write-Log -Message "Starter synkronisering fra kildegruppe $SourceGroupName til målgruppe $TargetGroupName." -Level "INFO"

        # Hente medlemmer fra kildegruppen (lokal Entra)
        $sourceMembers = Get-GroupMembers -GroupName $SourceGroupName | Where-Object { $_.AccountEnabled -eq $true }
        # Skriv ut medlemmer fra kildegruppen på en estetisk måte
        Write-Log -Message "Medlemmer i kildegruppen $SourceGroupName :" -Level "INFO"
        foreach ($member in $sourceMembers) {
            $memberInfo = @"
            ------------------------------
            Display Name : $($member.DisplayName)
            User Principal Name : $($member.UserPrincipalName)
            ID : $($member.Id)
            Mail: $($member.Mail)
            Enabled: $($member.AccountEnabled)
            ------------------------------
"@
            Write-Host $memberInfo -ForegroundColor Cyan
        }
        # Hente medlemmer fra målgruppen (Samhandling)
        $targetMembers = Get-TargetGroupMembers -GroupName $TargetGroupName
        
        # Finn medlemmer som mangler i målgruppen
        $membersToAdd = $sourceMembers | Where-Object { $_.Mail -notin $targetMembers.mail }
        
        # Legg til manglende medlemmer
        foreach ($member in $membersToAdd) {
            try {
                Invoke-RestMethod -Uri "$($apiUrl)/members/$($targetGroupName)" -Headers @{
                    "X-Functions-Key" = $FUNCTION_KEY
                    "X-County-Key" = $COUNTY_KEY
                    "Content-Type" = "application/json"
                } -Method Post -Body (@{ "displayName" = "$($member.DisplayName)"; "mail" = "$($member.Mail)" } | ConvertTo-Json -Depth 1)
                Write-Log -Message "La til medlem $($member.DisplayName) ($($member.Mail)) i gruppe $TargetGroupName." -Level "INFO"
            } catch {
                Write-Log -Message "Feil ved innmelding av medlem $($member.DisplayName) ($($member.Mail)) i gruppe $TargetGroupName : $_" -Level "ERROR"
            }
        }

        # Hent en oppdatert liste over medlemmer i målgruppen etter innmelding hvis det er medlemmer å legge til
        if ($membersToAdd.Count -gt 0) {
            Start-Sleep -Seconds 5 # Vent litt for å sikre at innmelding er fullført og evt mailendringer er oppdatert
            $targetMembers = Get-TargetGroupMembers -GroupName $TargetGroupName
            Write-Log -Message "Oppdaterte liste over medlemmer i målgruppen $TargetGroupName etter innmelding." -Level "INFO"
        } 

        # Finn medlemmer som skal fjernes fra målgruppen
        $membersToRemove = $targetMembers | Where-Object { $_.mail -notin $sourceMembers.Mail }
        
        # Fjern medlemmer som ikke lenger skal være medlem
        foreach ($member in $membersToRemove) {
            try {
                Invoke-RestMethod -Uri "$($apiUrl)/members/$($targetGroupName)/$($member.mail)" -Headers @{
                    "X-Functions-Key" = $FUNCTION_KEY
                    "X-County-Key" = $COUNTY_KEY
                } -Method Delete
                Write-Log -Message "Fjernet medlem $($member.displayName) ($($member.mail)) fra gruppe $TargetGroupName." -Level "INFO"
            } catch {
                Write-Log -Message "Feil ved fjerning av medlem $($member.displayName) ($($member.mail)) fra gruppe $TargetGroupName : $_" -Level "ERROR"
            }
        }
        
    } catch {
        Write-Log -Message "Feil under synkronisering av grupper $SourceGroupName til $TargetGroupName : $_" -Level "ERROR"
    }
}

# Hovedlogikk

try {
    Write-Log -Message "Starter synkronisering av grupper." -Level "INFO"

    # Iterer gjennom mappingen og synkroniser grupper
    foreach ($targetGroupName in $GROUP_MAPPING.Keys) {
        $sourceGroupName = $GROUP_MAPPING[$targetGroupName]
        Sync-GroupMembers -SourceGroupName $sourceGroupName -TargetGroupName $targetGroupName
    }

    Write-Log -Message "Synkronisering fullført." -Level "INFO"
} catch {
    Write-Log -Message "En uventet feil oppstod under synkronisering: $_" -Level "ERROR"
}