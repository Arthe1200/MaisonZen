param([string]$BaseUrl = 'http://127.0.0.1:5080')
$ErrorActionPreference = 'Stop'

function Invoke-Api($Method, $Path, $Token = $null, $Body = $null) {
    $headers = @{}
    if ($Token) { $headers.Authorization = "Bearer $Token" }
    $arguments = @{ Method = $Method; Uri = "$BaseUrl$Path"; Headers = $headers; ErrorAction = 'Stop' }
    if ($null -ne $Body) { $arguments.ContentType = 'application/json'; $arguments.Body = $Body | ConvertTo-Json -Depth 12 -Compress }
    Invoke-RestMethod @arguments
}

function New-VerifiedUser($Email, $Name) {
    $registration = Invoke-Api POST '/api/auth/register' $null @{ email = $Email; password = 'TestMaisonZen!2026'; displayName = $Name }
    if (-not $registration.developmentCode) { throw 'Development verification code was not returned.' }
    $verification = Invoke-Api POST '/api/auth/verify-email' $null @{ email = $Email; code = $registration.developmentCode }
    Invoke-Api PUT '/api/me/public-key' $verification.accessToken @{ publicKey = [Convert]::ToBase64String([byte[]](1..65)) } | Out-Null
    @{ userId = $verification.userId; token = $verification.accessToken }
}

function New-HouseholdSocket($HouseholdId, $Token) {
    $socket = [System.Net.WebSockets.ClientWebSocket]::new()
    $socket.Options.SetRequestHeader('Authorization', "Bearer $Token")
    $wsBase = $BaseUrl -replace '^http', 'ws'
    $socket.ConnectAsync([Uri]"$wsBase/api/realtime/$HouseholdId", [Threading.CancellationToken]::None).GetAwaiter().GetResult() | Out-Null
    $socket
}

$adult = New-VerifiedUser 'adult@maisonzen.test' 'Adulte Test'
$child = New-VerifiedUser 'child@maisonzen.test' 'Enfant Test'
$tenant = New-VerifiedUser 'tenant@maisonzen.test' 'Locataire Test'
$resetRequest = Invoke-Api POST '/api/auth/forgot-password' $null @{ email = 'adult@maisonzen.test' }
if (-not $resetRequest.developmentCode) { throw 'The password recovery code was not created.' }
Invoke-Api POST '/api/auth/reset-password' $null @{ email = 'adult@maisonzen.test'; code = $resetRequest.developmentCode; newPassword = 'ChangedMaisonZen!2026' } | Out-Null
$oldPasswordRejected = $false
try { Invoke-Api POST '/api/auth/login' $null @{ email = 'adult@maisonzen.test'; password = 'TestMaisonZen!2026' } | Out-Null } catch { $oldPasswordRejected = $true }
if (-not $oldPasswordRejected) { throw 'Password reset did not invalidate the old password.' }
$adultLogin = Invoke-Api POST '/api/auth/login' $null @{ email = 'adult@maisonzen.test'; password = 'ChangedMaisonZen!2026' }
$adult.token = $adultLogin.accessToken
$encryptedBackup = [Convert]::ToBase64String([byte[]](1..80))
Invoke-Api PUT '/api/me/recovery-backup' $adult.token @{ encryptedBackup = $encryptedBackup } | Out-Null
$storedBackup = Invoke-Api GET '/api/me/recovery-backup' $adult.token
if ($storedBackup.encryptedBackup -ne $encryptedBackup) { throw 'Encrypted recovery backup did not round-trip.' }

$household = Invoke-Api POST '/api/households' $adult.token @{ encryptedName = [Convert]::ToBase64String([byte[]](1..40)); keyEnvelope = [Convert]::ToBase64String([byte[]](1..40)) }
$householdId = $household.householdId

$inviteeKey = Invoke-Api GET '/api/users/public-key?email=child%40maisonzen.test' $adult.token
$invite = Invoke-Api POST "/api/households/$householdId/invites" $adult.token @{ email = 'child@maisonzen.test'; role = 'child'; keyEnvelope = [Convert]::ToBase64String([byte[]](1..48)) }
$joined = Invoke-Api POST '/api/households/accept-invite' $child.token @{ inviteCode = $invite.inviteCode }
if ($joined.role -ne 'child') { throw 'The child role was not preserved.' }
$tenantInvite = Invoke-Api POST "/api/households/$householdId/invites" $adult.token @{ email = 'tenant@maisonzen.test'; role = 'tenant'; keyEnvelope = [Convert]::ToBase64String([byte[]](4..51)) }
$tenantJoined = Invoke-Api POST '/api/households/accept-invite' $tenant.token @{ inviteCode = $tenantInvite.inviteCode }
if ($tenantJoined.role -ne 'tenant') { throw 'The tenant role was not preserved.' }
$childCannotRemoveMember = $false
try { Invoke-Api DELETE "/api/households/$householdId/members/$($adult.userId)" $child.token | Out-Null } catch { $childCannotRemoveMember = $true }
if (-not $childCannotRemoveMember) { throw 'A child was able to remove a household member.' }

$privateChildId = [Guid]::NewGuid()
$privateChild = @{ recordId = $privateChildId; audience = 'owner'; ownerId = $child.userId; allowedMemberIds = @(); ciphertext = [Convert]::ToBase64String([byte[]](1..48)) }
Invoke-Api POST "/api/households/$householdId/records" $child.token $privateChild | Out-Null

$adultBudget = @{ recordId = [Guid]::NewGuid(); audience = 'adults'; ownerId = $null; allowedMemberIds = @(); ciphertext = [Convert]::ToBase64String([byte[]](2..49)) }
Invoke-Api POST "/api/households/$householdId/records" $adult.token $adultBudget | Out-Null
$scopeEscalationRejected = $false
try {
    $stolenBudget = @{ recordId = $adultBudget.recordId; audience = 'owner'; ownerId = $child.userId; allowedMemberIds = @(); ciphertext = [Convert]::ToBase64String([byte[]](5..52)) }
    Invoke-Api PUT "/api/households/$householdId/records/$($adultBudget.recordId)" $child.token @{ expectedRevision = 1; record = $stolenBudget } | Out-Null
} catch { $scopeEscalationRejected = $true }
if (-not $scopeEscalationRejected) { throw 'A child was able to take ownership of an adult-only expense.' }

$sharedTask = @{ recordId = [Guid]::NewGuid(); audience = 'household'; ownerId = $null; allowedMemberIds = @(); ciphertext = [Convert]::ToBase64String([byte[]](3..50)) }
Invoke-Api POST "/api/households/$householdId/records" $adult.token $sharedTask | Out-Null

$adultRecords = Invoke-Api GET "/api/households/$householdId/records" $adult.token
$childRecords = Invoke-Api GET "/api/households/$householdId/records" $child.token
$tenantRecords = Invoke-Api GET "/api/households/$householdId/records" $tenant.token
if ($adultRecords.recordId -contains $privateChildId) { throw 'An adult could read the child personal record.' }
if ($childRecords.recordId -contains $adultBudget.recordId) { throw 'A child could read the adults-only budget.' }
if ($tenantRecords.recordId -contains $adultBudget.recordId) { throw 'A tenant could read the adults-only budget.' }
if ($adultRecords.recordId -notcontains $sharedTask.recordId -or $childRecords.recordId -notcontains $sharedTask.recordId) { throw 'The shared household task was not visible to both members.' }

$conflictRejected = $false
try {
    Invoke-Api PUT "/api/households/$householdId/records/$($sharedTask.recordId)" $adult.token @{ expectedRevision = 0; record = $sharedTask } | Out-Null
} catch { $conflictRejected = $true }
if (-not $conflictRejected) { throw 'The server accepted an update with a stale revision.' }

Invoke-Api DELETE "/api/households/$householdId/records/$privateChildId" $child.token | Out-Null
$tombstone = Invoke-Api GET "/api/households/$householdId/records" $child.token
if (-not ($tombstone | Where-Object { $_.recordId -eq $privateChildId -and $_.deleted })) { throw 'Deleted record was not retained as a tombstone.' }

$ice = Invoke-Api GET '/api/calls/ice-servers' $adult.token
if ($null -eq $ice.iceServers) { throw 'ICE server configuration response is malformed.' }

$adultSocket = New-HouseholdSocket $householdId $adult.token
$childSocket = New-HouseholdSocket $householdId $child.token
$tenantSocket = New-HouseholdSocket $householdId $tenant.token
$receiveBuffer = [byte[]]::new(4096)
$tenantBuffer = [byte[]]::new(4096)
$childReceive = $childSocket.ReceiveAsync([ArraySegment[byte]]::new($receiveBuffer), [Threading.CancellationToken]::None)
$tenantReceive = $tenantSocket.ReceiveAsync([ArraySegment[byte]]::new($tenantBuffer), [Threading.CancellationToken]::None)
$wireSignal = @{ recipientId = [string]$child.userId; callId = [string][Guid]::NewGuid(); ciphertext = 'opaque-end-to-end-test' } | ConvertTo-Json -Compress
$signalBytes = [Text.Encoding]::UTF8.GetBytes($wireSignal)
$adultSocket.SendAsync([ArraySegment[byte]]::new($signalBytes), [System.Net.WebSockets.WebSocketMessageType]::Text, $true, [Threading.CancellationToken]::None).GetAwaiter().GetResult() | Out-Null
$childEvent = $childReceive.WaitAsync([TimeSpan]::FromSeconds(3)).GetAwaiter().GetResult()
$relayedEvent = [Text.Encoding]::UTF8.GetString($receiveBuffer, 0, $childEvent.Count) | ConvertFrom-Json
if ($relayedEvent.type -ne 'signal' -or $relayedEvent.senderId -ne [string]$adult.userId) { throw 'The call signal did not reach its intended member.' }
$tenantWait = [Threading.Tasks.Task]::WhenAny($tenantReceive, [Threading.Tasks.Task]::Delay(500)).GetAwaiter().GetResult()
if ($tenantWait -eq $tenantReceive) { throw 'Call signaling was broadcast to an unrelated household member.' }
$signalRelayPrivate = $true

Invoke-Api DELETE "/api/households/$householdId/members/$($tenant.userId)" $adult.token | Out-Null
$connectionClosed = $false
try { $tenantReceive.WaitAsync([TimeSpan]::FromSeconds(3)).GetAwaiter().GetResult() | Out-Null } catch { }
$connectionClosed = $tenantSocket.State -ne [System.Net.WebSockets.WebSocketState]::Open
if (-not $connectionClosed) { throw 'Removing a member did not close their live connection.' }
foreach ($socket in @($adultSocket, $childSocket, $tenantSocket)) { $socket.Abort() }

[PSCustomObject]@{
    status = 'PASS'
    emailVerification = 'PASS'
    passwordReset = 'PASS'
    encryptedRecoveryBackup = 'PASS'
    householdInviteAndRoles = 'PASS'
    tenantRoleAndAdultsOnlyBudgetPrivacy = 'PASS'
    recordAccessScopeCannotBeEscalated = 'PASS'
    adminOnlyMemberRemoval = 'PASS'
    childPersonalAndAdultsOnlyVisibility = 'PASS'
    sharedRecordAccess = 'PASS'
    optimisticConflictProtection = 'PASS'
    softDeleteRetention = 'PASS'
    callRelayConfiguration = 'PASS'
    callSignalIsDeliveredOnlyToRecipient = 'PASS'
    removalClosesLiveConnection = 'PASS'
} | ConvertTo-Json -Depth 4
