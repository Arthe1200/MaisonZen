using System.Collections.Concurrent;
using System.Net;
using System.Net.Mail;
using System.Net.WebSockets;
using System.Security.Claims;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Microsoft.AspNetCore.RateLimiting;
using Microsoft.Data.Sqlite;
using Microsoft.Extensions.Options;
using System.Threading.RateLimiting;

var builder = WebApplication.CreateBuilder(args);
builder.Services.Configure<SmtpSettings>(builder.Configuration.GetSection("Smtp"));
builder.Services.AddSingleton<SecureStore>();
builder.Services.AddSingleton<TokenService>();
builder.Services.AddSingleton<Database>();
builder.Services.AddSingleton<Mailer>();
builder.Services.AddSingleton<RealtimeHub>();
builder.Services.AddHttpClient("products", client => client.Timeout = TimeSpan.FromSeconds(8));
builder.Services.AddRateLimiter(options =>
{
    options.RejectionStatusCode = StatusCodes.Status429TooManyRequests;
    options.AddPolicy("auth", context => RateLimitPartition.GetFixedWindowLimiter(
        context.Connection.RemoteIpAddress?.ToString() ?? "unknown",
        _ => new FixedWindowRateLimiterOptions { PermitLimit = 20, Window = TimeSpan.FromMinutes(1), QueueLimit = 0 }));
});

var app = builder.Build();
await app.Services.GetRequiredService<Database>().InitializeAsync();
if (!app.Environment.IsDevelopment())
{
    app.Use(async (context, next) =>
    {
        if (!context.Request.IsHttps)
        {
            context.Response.StatusCode = StatusCodes.Status400BadRequest;
            await context.Response.WriteAsync("HTTPS is required.");
            return;
        }
        await next();
    });
}
app.UseRateLimiter();
app.UseWebSockets(new WebSocketOptions { KeepAliveInterval = TimeSpan.FromSeconds(25) });
app.Use(async (context, next) =>
{
    var raw = context.Request.Headers.Authorization.ToString();
    var token = raw.StartsWith("Bearer ", StringComparison.OrdinalIgnoreCase) ? raw[7..] : "";
    var id = context.RequestServices.GetRequiredService<TokenService>().Validate(token);
    if (id is not null) context.User = new ClaimsPrincipal(new ClaimsIdentity([new Claim(ClaimTypes.NameIdentifier, id.Value.ToString())], "MaisonZen"));
    await next();
});

app.MapGet("/health", () => Results.Ok(new { status = "ok", service = "MaisonZen", utc = DateTimeOffset.UtcNow }));

app.MapPost("/api/auth/register", async (RegisterRequest request, Database db, SecureStore secure, Mailer mailer, IWebHostEnvironment env, CancellationToken ct) =>
{
    var email = NormalizeEmail(request.Email);
    if (!IsEmail(email) || request.Password.Length < 12 || request.Password.Length > 256 || string.IsNullOrWhiteSpace(request.DisplayName))
        return Results.BadRequest(new { error = "Utilise une adresse valide, un nom et un mot de passe d’au moins 12 caractères." });
    if (await db.EmailExistsAsync(secure.EmailLookup(email), ct)) return Results.Conflict(new { error = "Un compte existe déjà avec cette adresse." });

    var userId = Guid.NewGuid();
    var salt = RandomNumberGenerator.GetBytes(16);
    var passwordHash = HashPassword(request.Password, salt);
    var code = RandomNumberGenerator.GetInt32(0, 1_000_000).ToString("D6");
    var emailCipher = secure.Protect(Encoding.UTF8.GetBytes(email));
    var nameCipher = secure.Protect(Encoding.UTF8.GetBytes(request.DisplayName.Trim()));
    await db.CreateUserAsync(userId, secure.EmailLookup(email), emailCipher, nameCipher, salt, passwordHash, secure.HashCode(code), DateTimeOffset.UtcNow.AddMinutes(15), ct);
    var sent = await mailer.SendCodeAsync(email, code, "Vérifie ton compte MaisonZen", ct);
    if (!sent && !env.IsDevelopment()) return Results.Problem("Le service d’envoi d’e-mail n’est pas configuré.", statusCode: 503);
    return Results.Ok(new { userId, verificationRequired = true, developmentCode = env.IsDevelopment() && !sent ? code : null });
}).RequireRateLimiting("auth");

app.MapPost("/api/auth/verify-email", async (VerifyEmailRequest request, Database db, SecureStore secure, TokenService tokens, CancellationToken ct) =>
{
    var email = NormalizeEmail(request.Email);
    var user = await db.FindUserByEmailAsync(secure.EmailLookup(email), ct);
    if (user is null || user.Verified || user.CodeExpires < DateTimeOffset.UtcNow || !secure.FixedEquals(user.CodeHash, secure.HashCode(request.Code)))
        return Results.BadRequest(new { error = "Code invalide ou expiré." });
    await db.VerifyUserAsync(user.Id, ct);
    return Results.Ok(new AuthResponse(tokens.Create(user.Id), user.Id, user.Name));
}).RequireRateLimiting("auth");

app.MapPost("/api/auth/login", async (LoginRequest request, Database db, SecureStore secure, TokenService tokens, CancellationToken ct) =>
{
    var user = await db.FindUserByEmailAsync(secure.EmailLookup(NormalizeEmail(request.Email)), ct);
    if (user is null || !user.Verified || !VerifyPassword(request.Password, user.Salt, user.PasswordHash))
        return Results.Unauthorized();
    return Results.Ok(new AuthResponse(tokens.Create(user.Id), user.Id, user.Name));
}).RequireRateLimiting("auth");

app.MapPost("/api/auth/forgot-password", async (ForgotPasswordRequest request, Database db, SecureStore secure, Mailer mailer, IWebHostEnvironment env, CancellationToken ct) =>
{
    var email = NormalizeEmail(request.Email);
    var user = await db.FindUserByEmailAsync(secure.EmailLookup(email), ct);
    if (user is null) return Results.Ok(new { accepted = true });
    var code = RandomNumberGenerator.GetInt32(0, 1_000_000).ToString("D6");
    await db.SetResetCodeAsync(user.Id, secure.HashCode(code), DateTimeOffset.UtcNow.AddMinutes(15), ct);
    var sent = await mailer.SendCodeAsync(email, code, "Réinitialisation MaisonZen", ct);
    return Results.Ok(new { accepted = true, developmentCode = env.IsDevelopment() && !sent ? code : null });
}).RequireRateLimiting("auth");

app.MapPost("/api/auth/reset-password", async (ResetPasswordRequest request, Database db, SecureStore secure, CancellationToken ct) =>
{
    if (request.NewPassword.Length is < 12 or > 256) return Results.BadRequest(new { error = "Le mot de passe doit contenir entre 12 et 256 caractères." });
    var user = await db.FindUserByEmailAsync(secure.EmailLookup(NormalizeEmail(request.Email)), ct);
    if (user is null || user.ResetExpires < DateTimeOffset.UtcNow || !secure.FixedEquals(user.ResetHash, secure.HashCode(request.Code)))
        return Results.BadRequest(new { error = "Code invalide ou expiré." });
    var salt = RandomNumberGenerator.GetBytes(16);
    await db.ResetPasswordAsync(user.Id, salt, HashPassword(request.NewPassword, salt), ct);
    return Results.Ok(new { changed = true });
}).RequireRateLimiting("auth");

app.MapGet("/api/me", async (ClaimsPrincipal principal, Database db, CancellationToken ct) =>
{
    var userId = UserId(principal);
    var user = await db.FindUserAsync(userId, ct);
    return user is null ? Results.NotFound() : Results.Ok(new { userId, displayName = user.Name });
}).RequireAuth();

// Public keys are used only to wrap a household key for a member. The server never receives the clear household key.
app.MapPut("/api/me/public-key", async (ClaimsPrincipal principal, PublicKeyRequest request, Database db, CancellationToken ct) =>
{
    if (!TryBase64(request.PublicKey, out var key) || key.Length is < 32 or > 512) return Results.BadRequest(new { error = "Clé publique invalide." });
    await db.SetPublicKeyAsync(UserId(principal), key, ct);
    return Results.Ok(new { saved = true });
}).RequireAuth();

app.MapPut("/api/me/recovery-backup", async (ClaimsPrincipal principal, RecoveryBackupRequest request, Database db, CancellationToken ct) =>
{
    if (!TryBase64(request.EncryptedBackup, out var backup) || backup.Length is < 28 or > 131_072) return Results.BadRequest(new { error = "Sauvegarde chiffrée invalide." });
    await db.SetRecoveryBackupAsync(UserId(principal), backup, ct);
    return Results.Ok(new { saved = true });
}).RequireAuth();

app.MapGet("/api/me/recovery-backup", async (ClaimsPrincipal principal, Database db, CancellationToken ct) =>
{
    var backup = await db.GetRecoveryBackupAsync(UserId(principal), ct);
    return backup is null ? Results.NotFound(new { error = "Aucune sauvegarde de récupération n’existe pour ce compte." }) : Results.Ok(new { encryptedBackup = Convert.ToBase64String(backup) });
}).RequireAuth();

app.MapGet("/api/users/public-key", async (ClaimsPrincipal principal, string email, Database db, SecureStore secure, CancellationToken ct) =>
{
    var key = await db.GetPublicKeyByEmailAsync(secure.EmailLookup(NormalizeEmail(email)), ct);
    return key is null ? Results.NotFound(new { error = "Compte ou clé publique introuvable." }) : Results.Ok(new { publicKey = Convert.ToBase64String(key) });
}).RequireAuth();

app.MapPost("/api/households", async (ClaimsPrincipal principal, CreateHouseholdRequest request, Database db, CancellationToken ct) =>
{
    if (!TryBase64(request.EncryptedName, out var name) || name.Length > 4096 || !TryBase64(request.KeyEnvelope, out var envelope) || envelope.Length > 4096)
        return Results.BadRequest(new { error = "Informations chiffrées invalides." });
    var userId = UserId(principal);
    var householdId = Guid.NewGuid();
    await db.CreateHouseholdAsync(householdId, userId, name, envelope, ct);
    return Results.Ok(new HouseholdResponse(householdId, "admin", Convert.ToBase64String(name), Convert.ToBase64String(envelope)));
}).RequireAuth();

app.MapGet("/api/households", async (ClaimsPrincipal principal, Database db, CancellationToken ct) =>
    Results.Ok(await db.GetHouseholdsAsync(UserId(principal), ct))).RequireAuth();

app.MapGet("/api/households/{householdId:guid}/members", async (ClaimsPrincipal principal, Guid householdId, Database db, CancellationToken ct) =>
{
    if (!await db.IsMemberAsync(householdId, UserId(principal), ct)) return Results.Forbid();
    return Results.Ok(await db.GetMembersAsync(householdId, ct));
}).RequireAuth();

app.MapPost("/api/households/{householdId:guid}/invites", async (ClaimsPrincipal principal, Guid householdId, InviteRequest request, Database db, SecureStore secure, CancellationToken ct) =>
{
    var actorId = UserId(principal);
    var actorRole = await db.GetRoleAsync(householdId, actorId, ct);
    if (actorRole != "admin") return Results.Forbid();
    if (request.Role is not ("adult" or "child" or "tenant") || !TryBase64(request.KeyEnvelope, out var envelope) || envelope.Length > 4096)
        return Results.BadRequest(new { error = "Rôle ou enveloppe de clé invalide." });
    var email = NormalizeEmail(request.Email);
    var invitee = await db.FindUserByEmailAsync(secure.EmailLookup(email), ct);
    if (invitee is null || !invitee.Verified) return Results.BadRequest(new { error = "Le membre doit d’abord créer et vérifier son compte." });
    var token = Convert.ToBase64String(RandomNumberGenerator.GetBytes(32)).TrimEnd('=').Replace('+', '-').Replace('/', '_');
    await db.CreateInviteAsync(Guid.NewGuid(), householdId, invitee.Id, request.Role, secure.HashCode(token), envelope, DateTimeOffset.UtcNow.AddDays(7), ct);
    return Results.Ok(new { inviteCode = token, expiresInDays = 7 });
}).RequireAuth();

app.MapPost("/api/households/accept-invite", async (ClaimsPrincipal principal, AcceptInviteRequest request, Database db, SecureStore secure, CancellationToken ct) =>
{
    var accepted = await db.AcceptInviteAsync(secure.HashCode(request.InviteCode), UserId(principal), ct);
    return accepted is null ? Results.BadRequest(new { error = "Invitation invalide ou expirée." }) : Results.Ok(accepted);
}).RequireAuth();

app.MapDelete("/api/households/{householdId:guid}/members/{memberId:guid}", async (ClaimsPrincipal principal, Guid householdId, Guid memberId, Database db, RealtimeHub hub, CancellationToken ct) =>
{
    if (await db.GetRoleAsync(householdId, UserId(principal), ct) != "admin") return Results.Forbid();
    if (memberId == UserId(principal)) return Results.BadRequest(new { error = "L’administrateur doit transférer le foyer avant de le quitter." });
    await db.RemoveMemberAsync(householdId, memberId, ct);
    await hub.RemoveUserAsync(householdId, memberId);
    return Results.Ok(new { removed = true });
}).RequireAuth();

app.MapGet("/api/calls/ice-servers", (ClaimsPrincipal principal, IConfiguration configuration) =>
{
    var urls = configuration.GetSection("Turn:Urls").Get<string[]>() ?? [];
    var secret = configuration["MAISONZEN_TURN_SECRET"];
    if (urls.Length == 0 || string.IsNullOrWhiteSpace(secret)) return Results.Ok(new { iceServers = Array.Empty<object>() });
    var expiry = DateTimeOffset.UtcNow.AddHours(1).ToUnixTimeSeconds();
    var username = $"{expiry}:{UserId(principal)}";
    var credential = Convert.ToBase64String(new HMACSHA1(Encoding.UTF8.GetBytes(secret)).ComputeHash(Encoding.UTF8.GetBytes(username)));
    return Results.Ok(new { iceServers = new[] { new { urls, username, credential } } });
}).RequireAuth();

app.MapGet("/api/households/{householdId:guid}/records", async (ClaimsPrincipal principal, Guid householdId, Database db, string? updatedAfter, CancellationToken ct) =>
{
    var userId = UserId(principal);
    var role = await db.GetRoleAsync(householdId, userId, ct);
    if (role is null) return Results.Forbid();
    DateTimeOffset? since = DateTimeOffset.TryParse(updatedAfter, out var parsed) ? parsed : null;
    return Results.Ok(await db.GetRecordsAsync(householdId, userId, role, since, ct));
}).RequireAuth();

app.MapPost("/api/households/{householdId:guid}/records", async (ClaimsPrincipal principal, Guid householdId, SaveRecordRequest request, Database db, RealtimeHub hub, CancellationToken ct) =>
{
    var userId = UserId(principal);
    var role = await db.GetRoleAsync(householdId, userId, ct);
    if (role is null) return Results.Forbid();
    if (!ValidRecord(request)) return Results.BadRequest(new { error = "Enregistrement chiffré invalide." });
    if (!RecordPolicy.CanWrite(request.Audience, request.OwnerId, request.AllowedMemberIds, userId, role)) return Results.Forbid();
    var result = await db.CreateRecordAsync(householdId, request, userId, ct);
    if (result is null) return Results.Conflict(new { error = "Cet identifiant existe déjà." });
    await hub.BroadcastAsync(householdId, new { type = "record_changed", recordId = request.RecordId, revision = 1 }, ct);
    return Results.Ok(result);
}).RequireAuth();

app.MapPut("/api/households/{householdId:guid}/records/{recordId:guid}", async (ClaimsPrincipal principal, Guid householdId, Guid recordId, UpdateRecordRequest request, Database db, RealtimeHub hub, CancellationToken ct) =>
{
    var userId = UserId(principal);
    var role = await db.GetRoleAsync(householdId, userId, ct);
    if (role is null) return Results.Forbid();
    if (request.Record.RecordId != recordId) return Results.BadRequest(new { error = "L’identifiant du contenu ne correspond pas à l’adresse demandée." });
    if (!ValidRecord(request.Record)) return Results.BadRequest(new { error = "Enregistrement chiffré invalide." });
    if (!RecordPolicy.CanWrite(request.Record.Audience, request.Record.OwnerId, request.Record.AllowedMemberIds, userId, role)) return Results.Forbid();
    var saved = await db.UpdateRecordAsync(householdId, recordId, request, userId, role, ct);
    if (saved is null) return Results.Conflict(new { error = "La version a changé. Synchronise puis réessaie." });
    await hub.BroadcastAsync(householdId, new { type = "record_changed", recordId, revision = saved.Revision }, ct);
    return Results.Ok(saved);
}).RequireAuth();

app.MapDelete("/api/households/{householdId:guid}/records/{recordId:guid}", async (ClaimsPrincipal principal, Guid householdId, Guid recordId, Database db, RealtimeHub hub, CancellationToken ct) =>
{
    var userId = UserId(principal);
    var role = await db.GetRoleAsync(householdId, userId, ct);
    if (role is null) return Results.Forbid();
    var result = await db.TombstoneRecordAsync(householdId, recordId, userId, role, ct);
    if (!result) return Results.Forbid();
    await hub.BroadcastAsync(householdId, new { type = "record_deleted", recordId }, ct);
    return Results.Ok(new { deleted = true, retainedAsTombstone = true });
}).RequireAuth();

app.MapGet("/api/products/{barcode}", async (string barcode, IHttpClientFactory clients, CancellationToken ct) =>
{
    if (barcode.Length is < 8 or > 14 || barcode.Any(c => !char.IsAsciiDigit(c))) return Results.BadRequest(new { error = "Code-barres invalide." });
    try
    {
        var response = await clients.CreateClient("products").GetAsync($"https://world.openfoodfacts.org/api/v2/product/{barcode}.json?fields=product_name,brands,quantity,image_url", ct);
        if (!response.IsSuccessStatusCode) return Results.NotFound();
        using var json = JsonDocument.Parse(await response.Content.ReadAsStringAsync(ct));
        if (json.RootElement.GetProperty("status").GetInt32() != 1) return Results.NotFound();
        var p = json.RootElement.GetProperty("product");
        return Results.Ok(new { barcode, name = p.TryGetProperty("product_name", out var n) ? n.GetString() : null, brand = p.TryGetProperty("brands", out var b) ? b.GetString() : null, quantity = p.TryGetProperty("quantity", out var q) ? q.GetString() : null, imageUrl = p.TryGetProperty("image_url", out var i) ? i.GetString() : null });
    }
    catch (HttpRequestException) { return Results.Problem("La base de produits est momentanément indisponible.", statusCode: 503); }
}).RequireAuth();

app.Map("/api/realtime/{householdId:guid}", async (HttpContext context, Guid householdId, Database db, TokenService tokens, RealtimeHub hub) =>
{
    var token = context.Request.Headers.Authorization.ToString().Replace("Bearer ", "", StringComparison.OrdinalIgnoreCase);
    var userId = tokens.Validate(token);
    if (userId is null || !await db.IsMemberAsync(householdId, userId.Value, context.RequestAborted)) { context.Response.StatusCode = 401; return; }
    if (!context.WebSockets.IsWebSocketRequest) { context.Response.StatusCode = 400; return; }
    using var socket = await context.WebSockets.AcceptWebSocketAsync();
    await hub.RunAsync(householdId, userId.Value, socket, context.RequestAborted);
});

app.Run();

static string NormalizeEmail(string value) => value.Trim().ToLowerInvariant();
static bool IsEmail(string value) => value.Length <= 254 && value.Contains('@') && value.LastIndexOf('.') > value.IndexOf('@') + 1;
static Guid UserId(ClaimsPrincipal principal) => Guid.Parse(principal.FindFirstValue(ClaimTypes.NameIdentifier)!);
static bool TryBase64(string value, out byte[] bytes) { try { bytes = Convert.FromBase64String(value); return true; } catch { bytes = []; return false; } }
static byte[] HashPassword(string password, byte[] salt) => Rfc2898DeriveBytes.Pbkdf2(password, salt, 600_000, HashAlgorithmName.SHA256, 32);
static bool VerifyPassword(string password, byte[] salt, byte[] expected) => CryptographicOperations.FixedTimeEquals(HashPassword(password, salt), expected);
static bool ValidRecord(SaveRecordRequest request) => Guid.TryParse(request.RecordId.ToString(), out _) && TryBase64(request.Ciphertext, out var c) && c.Length is > 28 and <= 1_048_576 && request.Audience is "owner" or "adults" or "household" or "members" && request.AllowedMemberIds.Count <= 64;
static class EndpointAuthExtensions
{
    public static RouteHandlerBuilder RequireAuth(this RouteHandlerBuilder endpoint, TokenService? tokens = null)
    {
        endpoint.AddEndpointFilter(async (invocation, next) =>
        {
            var context = invocation.HttpContext;
            var service = context.RequestServices.GetRequiredService<TokenService>();
            var raw = context.Request.Headers.Authorization.ToString();
            var id = service.Validate(raw.StartsWith("Bearer ", StringComparison.OrdinalIgnoreCase) ? raw[7..] : "");
            if (id is null) return Results.Unauthorized();
            context.User = new ClaimsPrincipal(new ClaimsIdentity([new Claim(ClaimTypes.NameIdentifier, id.Value.ToString())], "MaisonZen"));
            return await next(invocation);
        });
        return endpoint;
    }
}

static class RecordPolicy
{
    public static bool CanWrite(string audience, Guid? owner, IReadOnlyList<Guid> allowed, Guid actor, string role) => audience switch
    {
        "owner" => owner == actor,
        "adults" => role is "adult" or "admin",
        "household" => true,
        "members" => allowed.Contains(actor),
        _ => false
    };
    public static bool CanRead(string audience, Guid? owner, IReadOnlyList<Guid> allowed, Guid actor, string role) => CanWrite(audience, owner, allowed, actor, role);
}

record RegisterRequest(string Email, string Password, string DisplayName);
record VerifyEmailRequest(string Email, string Code);
record LoginRequest(string Email, string Password);
record ForgotPasswordRequest(string Email);
record ResetPasswordRequest(string Email, string Code, string NewPassword);
record PublicKeyRequest(string PublicKey);
record RecoveryBackupRequest(string EncryptedBackup);
record CreateHouseholdRequest(string EncryptedName, string KeyEnvelope);
record InviteRequest(string Email, string Role, string KeyEnvelope);
record AcceptInviteRequest(string InviteCode);
record SaveRecordRequest(Guid RecordId, string Audience, Guid? OwnerId, IReadOnlyList<Guid> AllowedMemberIds, string Ciphertext);
record UpdateRecordRequest(long ExpectedRevision, SaveRecordRequest Record);
record AuthResponse(string AccessToken, Guid UserId, string DisplayName);
record HouseholdResponse(Guid HouseholdId, string Role, string EncryptedName, string KeyEnvelope);
record SmtpSettings { public string Host { get; init; } = ""; public int Port { get; init; } = 587; public string User { get; init; } = ""; public string Password { get; init; } = ""; public string From { get; init; } = ""; }

sealed class SecureStore(IConfiguration configuration, IWebHostEnvironment env)
{
    private readonly byte[] _key = LoadKey(configuration, env);
    private static byte[] LoadKey(IConfiguration configuration, IWebHostEnvironment env)
    {
        var value = configuration["MAISONZEN_DATA_KEY"];
        if (string.IsNullOrWhiteSpace(value) && env.IsDevelopment()) return SHA256.HashData(Encoding.UTF8.GetBytes("MaisonZen local development data key; replace before use"));
        try { var key = Convert.FromBase64String(value ?? ""); if (key.Length == 32) return key; } catch { }
        throw new InvalidOperationException("Set MAISONZEN_DATA_KEY to a base64 encoded 32-byte key before starting the server.");
    }
    public byte[] Protect(byte[] clear)
    {
        var nonce = RandomNumberGenerator.GetBytes(12); var cipher = new byte[clear.Length]; var tag = new byte[16];
        using var aes = new AesGcm(_key, 16); aes.Encrypt(nonce, clear, cipher, tag);
        return [.. nonce, .. tag, .. cipher];
    }
    public byte[] Unprotect(byte[] encrypted)
    {
        if (encrypted.Length < 28) throw new CryptographicException("Encrypted field is truncated.");
        var nonce = encrypted[..12]; var tag = encrypted[12..28]; var cipher = encrypted[28..]; var clear = new byte[cipher.Length];
        using var aes = new AesGcm(_key, 16); aes.Decrypt(nonce, cipher, tag, clear); return clear;
    }
    public string EmailLookup(string email) => Convert.ToHexString(HMACSHA256.HashData(_key, Encoding.UTF8.GetBytes(email)));
    public byte[] HashCode(string code) => HMACSHA256.HashData(_key, Encoding.UTF8.GetBytes(code));
    public bool FixedEquals(byte[]? a, byte[] b) => a is not null && a.Length == b.Length && CryptographicOperations.FixedTimeEquals(a, b);
}

sealed class TokenService(IConfiguration configuration, IWebHostEnvironment env)
{
    private readonly byte[] _key = GetKey(configuration, env);
    private static byte[] GetKey(IConfiguration configuration, IWebHostEnvironment env)
    {
        var value = configuration["MAISONZEN_TOKEN_KEY"];
        if (string.IsNullOrWhiteSpace(value) && env.IsDevelopment()) return SHA256.HashData(Encoding.UTF8.GetBytes("MaisonZen local development token signing key; replace before use"));
        try { var key = Convert.FromBase64String(value ?? ""); if (key.Length >= 32) return key; } catch { }
        throw new InvalidOperationException("Set MAISONZEN_TOKEN_KEY to a base64 encoded secret of at least 32 bytes.");
    }
    public string Create(Guid userId)
    {
        var payload = JsonSerializer.SerializeToUtf8Bytes(new TokenPayload(userId, DateTimeOffset.UtcNow.AddHours(12).ToUnixTimeSeconds()));
        var encoded = Base64Url(payload); var signature = HMACSHA256.HashData(_key, Encoding.ASCII.GetBytes(encoded));
        return $"{encoded}.{Base64Url(signature)}";
    }
    public Guid? Validate(string token)
    {
        var parts = token.Split('.'); if (parts.Length != 2) return null;
        try
        {
            var actual = FromBase64Url(parts[1]); var expected = HMACSHA256.HashData(_key, Encoding.ASCII.GetBytes(parts[0]));
            if (!CryptographicOperations.FixedTimeEquals(actual, expected)) return null;
            var payload = JsonSerializer.Deserialize<TokenPayload>(FromBase64Url(parts[0]));
            return payload is not null && payload.Expires > DateTimeOffset.UtcNow.ToUnixTimeSeconds() ? payload.UserId : null;
        }
        catch { return null; }
    }
    private static string Base64Url(byte[] bytes) => Convert.ToBase64String(bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_');
    private static byte[] FromBase64Url(string value) => Convert.FromBase64String(value.Replace('-', '+').Replace('_', '/') + new string('=', (4 - value.Length % 4) % 4));
    private sealed record TokenPayload(Guid UserId, long Expires);
}

sealed class Mailer(IOptions<SmtpSettings> options, ILogger<Mailer> logger)
{
    public async Task<bool> SendCodeAsync(string email, string code, string subject, CancellationToken ct)
    {
        var settings = options.Value;
        if (string.IsNullOrWhiteSpace(settings.Host) || string.IsNullOrWhiteSpace(settings.From)) { logger.LogWarning("SMTP is not configured; no verification email sent."); return false; }
        using var message = new MailMessage(settings.From, email, subject, $"Ton code MaisonZen est {code}. Il expire dans 15 minutes.");
        using var client = new SmtpClient(settings.Host, settings.Port) { EnableSsl = true };
        if (!string.IsNullOrWhiteSpace(settings.User)) client.Credentials = new NetworkCredential(settings.User, settings.Password);
        await client.SendMailAsync(message, ct); return true;
    }
}

sealed class RealtimeHub
{
    private readonly ConcurrentDictionary<Guid, ConcurrentDictionary<Guid, RealtimePeer>> _sockets = new();
    public async Task RunAsync(Guid householdId, Guid userId, WebSocket socket, CancellationToken ct)
    {
        var peers = _sockets.GetOrAdd(householdId, _ => new()); var connectionId = Guid.NewGuid(); peers[connectionId] = new(userId, socket);
        var buffer = new byte[64 * 1024];
        try
        {
            while (socket.State == WebSocketState.Open && !ct.IsCancellationRequested)
            {
                var result = await socket.ReceiveAsync(buffer, ct);
                if (result.MessageType == WebSocketMessageType.Close) break;
                if (result.MessageType != WebSocketMessageType.Text || result.Count > 32 * 1024) continue;
                // Signaling payloads are opaque end-to-end ciphertext. The server only relays them.
                var envelope = Encoding.UTF8.GetString(buffer, 0, result.Count);
                Guid recipientId;
                try
                {
                    using var parsed = JsonDocument.Parse(envelope);
                    if (!parsed.RootElement.TryGetProperty("recipientId", out var recipient) || recipient.ValueKind != JsonValueKind.String || !Guid.TryParse(recipient.GetString(), out recipientId)) continue;
                }
                catch (JsonException) { continue; }
                await SendToUserAsync(householdId, recipientId, new { type = "signal", senderId = userId, envelope }, ct);
            }
        }
        catch (OperationCanceledException) { }
        catch (WebSocketException) { }
        finally { peers.TryRemove(connectionId, out _); if (socket.State == WebSocketState.Open) await socket.CloseAsync(WebSocketCloseStatus.NormalClosure, "", CancellationToken.None); }
    }
    public Task RemoveUserAsync(Guid householdId, Guid userId)
    {
        if (!_sockets.TryGetValue(householdId, out var peers)) return Task.CompletedTask;
        foreach (var pair in peers.ToArray().Where(pair => pair.Value.UserId == userId))
        {
            if (!peers.TryRemove(pair.Key, out var peer)) continue;
            peer.Socket.Abort();
        }
        return Task.CompletedTask;
    }
    public async Task BroadcastAsync(Guid householdId, object value, CancellationToken ct, Guid? except = null)
    {
        if (!_sockets.TryGetValue(householdId, out var peers)) return;
        var bytes = JsonSerializer.SerializeToUtf8Bytes(value);
        foreach (var pair in peers.ToArray())
            if (pair.Key != except && pair.Value.Socket.State == WebSocketState.Open)
                try { await pair.Value.Socket.SendAsync(bytes, WebSocketMessageType.Text, true, ct); } catch (WebSocketException) { peers.TryRemove(pair.Key, out _); }
    }
    private async Task SendToUserAsync(Guid householdId, Guid userId, object value, CancellationToken ct)
    {
        if (!_sockets.TryGetValue(householdId, out var peers)) return;
        var bytes = JsonSerializer.SerializeToUtf8Bytes(value);
        foreach (var pair in peers.ToArray().Where(pair => pair.Value.UserId == userId))
            if (pair.Value.Socket.State == WebSocketState.Open)
                try { await pair.Value.Socket.SendAsync(bytes, WebSocketMessageType.Text, true, ct); } catch (WebSocketException) { peers.TryRemove(pair.Key, out _); }
    }
    private sealed record RealtimePeer(Guid UserId, WebSocket Socket);
}

sealed class Database(IConfiguration configuration, SecureStore secure)
{
    private readonly string _connectionString = new SqliteConnectionStringBuilder { DataSource = Path.GetFullPath(configuration["DatabasePath"] ?? "data/maisonzen.db"), Mode = SqliteOpenMode.ReadWriteCreate, Cache = SqliteCacheMode.Shared }.ToString();
    private SqliteConnection Open() => new(_connectionString);
    public async Task InitializeAsync()
    {
        Directory.CreateDirectory(Path.GetDirectoryName(new SqliteConnectionStringBuilder(_connectionString).DataSource)!);
        await using var c = Open(); await c.OpenAsync();
        await using var cmd = c.CreateCommand();
        cmd.CommandText = """
        PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON;
        CREATE TABLE IF NOT EXISTS users(id TEXT PRIMARY KEY,email_lookup TEXT NOT NULL UNIQUE,email_cipher BLOB NOT NULL,name_cipher BLOB NOT NULL,password_salt BLOB NOT NULL,password_hash BLOB NOT NULL,verified INTEGER NOT NULL,code_hash BLOB,code_expires TEXT,reset_hash BLOB,reset_expires TEXT,public_key BLOB,recovery_backup BLOB,created_at TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS households(id TEXT PRIMARY KEY,owner_id TEXT NOT NULL,cipher_name BLOB NOT NULL,created_at TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS memberships(household_id TEXT NOT NULL,user_id TEXT NOT NULL,role TEXT NOT NULL,key_envelope BLOB NOT NULL,joined_at TEXT NOT NULL,PRIMARY KEY(household_id,user_id));
        CREATE TABLE IF NOT EXISTS invites(id TEXT PRIMARY KEY,household_id TEXT NOT NULL,invitee_id TEXT NOT NULL,role TEXT NOT NULL,token_hash BLOB NOT NULL UNIQUE,key_envelope BLOB NOT NULL,expires_at TEXT NOT NULL,accepted INTEGER NOT NULL DEFAULT 0);
        CREATE TABLE IF NOT EXISTS records(household_id TEXT NOT NULL,id TEXT NOT NULL,audience TEXT NOT NULL,owner_id TEXT,allowed_members TEXT NOT NULL,ciphertext BLOB NOT NULL,revision INTEGER NOT NULL,updated_at TEXT NOT NULL,deleted INTEGER NOT NULL DEFAULT 0,PRIMARY KEY(household_id,id));
        CREATE INDEX IF NOT EXISTS records_updated ON records(household_id,updated_at);
        """;
        await cmd.ExecuteNonQueryAsync();
        await using var columns = c.CreateCommand(); columns.CommandText = "PRAGMA table_info(users);";
        await using var reader = await columns.ExecuteReaderAsync(); var hasRecoveryBackup = false;
        while (await reader.ReadAsync()) if (reader.GetString(1) == "recovery_backup") hasRecoveryBackup = true;
        await reader.DisposeAsync();
        if (!hasRecoveryBackup) { await using var alter = c.CreateCommand(); alter.CommandText = "ALTER TABLE users ADD COLUMN recovery_backup BLOB;"; await alter.ExecuteNonQueryAsync(); }
    }
    public async Task<bool> EmailExistsAsync(string lookup, CancellationToken ct) { await using var c = Open(); await c.OpenAsync(ct); await using var q = c.CreateCommand(); q.CommandText = "SELECT 1 FROM users WHERE email_lookup=$e"; q.Parameters.AddWithValue("$e", lookup); return await q.ExecuteScalarAsync(ct) is not null; }
    public async Task CreateUserAsync(Guid id, string lookup, byte[] email, byte[] name, byte[] salt, byte[] hash, byte[] codeHash, DateTimeOffset expires, CancellationToken ct)
    {
        await using var c = Open(); await c.OpenAsync(ct); await using var q = c.CreateCommand(); q.CommandText = "INSERT INTO users(id,email_lookup,email_cipher,name_cipher,password_salt,password_hash,verified,code_hash,code_expires,created_at) VALUES($i,$e,$m,$n,$s,$p,0,$c,$x,$t)";
        q.Parameters.AddWithValue("$i", id.ToString()); q.Parameters.AddWithValue("$e", lookup); q.Parameters.AddWithValue("$m", email); q.Parameters.AddWithValue("$n", name); q.Parameters.AddWithValue("$s", salt); q.Parameters.AddWithValue("$p", hash); q.Parameters.AddWithValue("$c", codeHash); q.Parameters.AddWithValue("$x", expires.ToString("O")); q.Parameters.AddWithValue("$t", DateTimeOffset.UtcNow.ToString("O")); await q.ExecuteNonQueryAsync(ct);
    }
    public async Task<UserRow?> FindUserByEmailAsync(string lookup, CancellationToken ct)
    {
        await using var c = Open(); await c.OpenAsync(ct); await using var q = c.CreateCommand(); q.CommandText = "SELECT * FROM users WHERE email_lookup=$e"; q.Parameters.AddWithValue("$e", lookup); await using var r = await q.ExecuteReaderAsync(ct); return await r.ReadAsync(ct) ? ReadUser(r) : null;
    }
    public async Task<UserRow?> FindUserAsync(Guid id, CancellationToken ct)
    {
        await using var c = Open(); await c.OpenAsync(ct); await using var q = c.CreateCommand(); q.CommandText = "SELECT * FROM users WHERE id=$i"; q.Parameters.AddWithValue("$i", id.ToString()); await using var r = await q.ExecuteReaderAsync(ct); return await r.ReadAsync(ct) ? ReadUser(r) : null;
    }
    private UserRow ReadUser(SqliteDataReader r) => new(Guid.Parse(r.GetString(r.GetOrdinal("id"))), secure.Unprotect((byte[])r["name_cipher"]) is var n ? Encoding.UTF8.GetString(n) : "", (byte[])r["password_salt"], (byte[])r["password_hash"], Convert.ToInt64(r["verified"]) == 1, r["code_hash"] as byte[], DateTimeOffset.TryParse(r["code_expires"] as string, out var ce) ? ce : DateTimeOffset.MinValue, r["reset_hash"] as byte[], DateTimeOffset.TryParse(r["reset_expires"] as string, out var re) ? re : DateTimeOffset.MinValue);
    public async Task VerifyUserAsync(Guid id, CancellationToken ct) { await using var c = Open(); await c.OpenAsync(ct); await using var q = c.CreateCommand(); q.CommandText = "UPDATE users SET verified=1,code_hash=NULL,code_expires=NULL WHERE id=$i"; q.Parameters.AddWithValue("$i", id.ToString()); await q.ExecuteNonQueryAsync(ct); }
    public async Task SetResetCodeAsync(Guid id, byte[] hash, DateTimeOffset expiry, CancellationToken ct) { await using var c = Open(); await c.OpenAsync(ct); await using var q = c.CreateCommand(); q.CommandText = "UPDATE users SET reset_hash=$h,reset_expires=$x WHERE id=$i"; q.Parameters.AddWithValue("$h", hash); q.Parameters.AddWithValue("$x", expiry.ToString("O")); q.Parameters.AddWithValue("$i", id.ToString()); await q.ExecuteNonQueryAsync(ct); }
    public async Task ResetPasswordAsync(Guid id, byte[] salt, byte[] hash, CancellationToken ct) { await using var c = Open(); await c.OpenAsync(ct); await using var q = c.CreateCommand(); q.CommandText = "UPDATE users SET password_salt=$s,password_hash=$p,reset_hash=NULL,reset_expires=NULL WHERE id=$i"; q.Parameters.AddWithValue("$s", salt); q.Parameters.AddWithValue("$p", hash); q.Parameters.AddWithValue("$i", id.ToString()); await q.ExecuteNonQueryAsync(ct); }
    public async Task SetPublicKeyAsync(Guid id, byte[] key, CancellationToken ct) { await using var c = Open(); await c.OpenAsync(ct); await using var q = c.CreateCommand(); q.CommandText = "UPDATE users SET public_key=$k WHERE id=$i"; q.Parameters.AddWithValue("$k", key); q.Parameters.AddWithValue("$i", id.ToString()); await q.ExecuteNonQueryAsync(ct); }
    public async Task SetRecoveryBackupAsync(Guid id, byte[] backup, CancellationToken ct) { await using var c = Open(); await c.OpenAsync(ct); await using var q = c.CreateCommand(); q.CommandText = "UPDATE users SET recovery_backup=$b WHERE id=$i"; q.Parameters.AddWithValue("$b", backup); q.Parameters.AddWithValue("$i", id.ToString()); await q.ExecuteNonQueryAsync(ct); }
    public async Task<byte[]?> GetRecoveryBackupAsync(Guid id, CancellationToken ct) { await using var c = Open(); await c.OpenAsync(ct); await using var q = c.CreateCommand(); q.CommandText = "SELECT recovery_backup FROM users WHERE id=$i"; q.Parameters.AddWithValue("$i", id.ToString()); return await q.ExecuteScalarAsync(ct) as byte[]; }
    public async Task<byte[]?> GetPublicKeyByEmailAsync(string email, CancellationToken ct) { await using var c = Open(); await c.OpenAsync(ct); await using var q = c.CreateCommand(); q.CommandText = "SELECT public_key FROM users WHERE email_lookup=$e AND verified=1"; q.Parameters.AddWithValue("$e", email); return await q.ExecuteScalarAsync(ct) as byte[]; }
    public async Task CreateHouseholdAsync(Guid id, Guid owner, byte[] name, byte[] envelope, CancellationToken ct)
    {
        await using var c = Open(); await c.OpenAsync(ct); await using var tx = await c.BeginTransactionAsync(ct);
        await using (var q = c.CreateCommand()) { q.Transaction = (SqliteTransaction)tx; q.CommandText = "INSERT INTO households(id,owner_id,cipher_name,created_at) VALUES($h,$o,$n,$t)"; q.Parameters.AddWithValue("$h", id.ToString()); q.Parameters.AddWithValue("$o", owner.ToString()); q.Parameters.AddWithValue("$n", name); q.Parameters.AddWithValue("$t", DateTimeOffset.UtcNow.ToString("O")); await q.ExecuteNonQueryAsync(ct); }
        await using (var q = c.CreateCommand()) { q.Transaction = (SqliteTransaction)tx; q.CommandText = "INSERT INTO memberships(household_id,user_id,role,key_envelope,joined_at) VALUES($h,$u,'admin',$k,$t)"; q.Parameters.AddWithValue("$h", id.ToString()); q.Parameters.AddWithValue("$u", owner.ToString()); q.Parameters.AddWithValue("$k", envelope); q.Parameters.AddWithValue("$t", DateTimeOffset.UtcNow.ToString("O")); await q.ExecuteNonQueryAsync(ct); }
        await tx.CommitAsync(ct);
    }
    public async Task<IReadOnlyList<HouseholdResponse>> GetHouseholdsAsync(Guid user, CancellationToken ct)
    {
        var list = new List<HouseholdResponse>(); await using var c = Open(); await c.OpenAsync(ct); await using var q = c.CreateCommand(); q.CommandText = "SELECT h.id,m.role,h.cipher_name,m.key_envelope FROM households h JOIN memberships m ON m.household_id=h.id WHERE m.user_id=$u"; q.Parameters.AddWithValue("$u", user.ToString()); await using var r = await q.ExecuteReaderAsync(ct); while (await r.ReadAsync(ct)) list.Add(new(Guid.Parse(r.GetString(0)), r.GetString(1), Convert.ToBase64String((byte[])r[2]), Convert.ToBase64String((byte[])r[3]))); return list;
    }
    public async Task<bool> IsMemberAsync(Guid household, Guid user, CancellationToken ct) => await GetRoleAsync(household, user, ct) is not null;
    public async Task<string?> GetRoleAsync(Guid household, Guid user, CancellationToken ct) { await using var c = Open(); await c.OpenAsync(ct); await using var q = c.CreateCommand(); q.CommandText = "SELECT role FROM memberships WHERE household_id=$h AND user_id=$u"; q.Parameters.AddWithValue("$h", household.ToString()); q.Parameters.AddWithValue("$u", user.ToString()); return await q.ExecuteScalarAsync(ct) as string; }
    public async Task<IReadOnlyList<object>> GetMembersAsync(Guid household, CancellationToken ct)
    {
        var list = new List<object>(); await using var c = Open(); await c.OpenAsync(ct); await using var q = c.CreateCommand(); q.CommandText = "SELECT u.id,u.name_cipher,m.role,m.key_envelope FROM memberships m JOIN users u ON u.id=m.user_id WHERE m.household_id=$h"; q.Parameters.AddWithValue("$h", household.ToString()); await using var r = await q.ExecuteReaderAsync(ct); while (await r.ReadAsync(ct)) list.Add(new { userId = Guid.Parse(r.GetString(0)), displayName = Encoding.UTF8.GetString(secure.Unprotect((byte[])r[1])), role = r.GetString(2), keyEnvelope = Convert.ToBase64String((byte[])r[3]) }); return list;
    }
    public async Task CreateInviteAsync(Guid id, Guid household, Guid invitee, string role, byte[] tokenHash, byte[] envelope, DateTimeOffset expiry, CancellationToken ct) { await using var c = Open(); await c.OpenAsync(ct); await using var q = c.CreateCommand(); q.CommandText = "INSERT INTO invites(id,household_id,invitee_id,role,token_hash,key_envelope,expires_at) VALUES($i,$h,$u,$r,$t,$k,$x)"; q.Parameters.AddWithValue("$i", id.ToString()); q.Parameters.AddWithValue("$h", household.ToString()); q.Parameters.AddWithValue("$u", invitee.ToString()); q.Parameters.AddWithValue("$r", role); q.Parameters.AddWithValue("$t", tokenHash); q.Parameters.AddWithValue("$k", envelope); q.Parameters.AddWithValue("$x", expiry.ToString("O")); await q.ExecuteNonQueryAsync(ct); }
    public async Task<object?> AcceptInviteAsync(byte[] tokenHash, Guid user, CancellationToken ct)
    {
        await using var c = Open(); await c.OpenAsync(ct); await using var tx = await c.BeginTransactionAsync(ct); await using var q = c.CreateCommand(); q.Transaction = (SqliteTransaction)tx; q.CommandText = "SELECT id,household_id,role,key_envelope,expires_at,accepted,invitee_id FROM invites WHERE token_hash=$t"; q.Parameters.AddWithValue("$t", tokenHash); await using var r = await q.ExecuteReaderAsync(ct); if (!await r.ReadAsync(ct) || r.GetInt64(5) != 0 || Guid.Parse(r.GetString(6)) != user || !DateTimeOffset.TryParse(r.GetString(4), out var expiry) || expiry < DateTimeOffset.UtcNow) return null; var inviteId = r.GetString(0); var hid = r.GetString(1); var role = r.GetString(2); var key = (byte[])r[3]; await r.DisposeAsync();
        await using (var add = c.CreateCommand()) { add.Transaction = (SqliteTransaction)tx; add.CommandText = "INSERT INTO memberships(household_id,user_id,role,key_envelope,joined_at) VALUES($h,$u,$r,$k,$t)"; add.Parameters.AddWithValue("$h", hid); add.Parameters.AddWithValue("$u", user.ToString()); add.Parameters.AddWithValue("$r", role); add.Parameters.AddWithValue("$k", key); add.Parameters.AddWithValue("$t", DateTimeOffset.UtcNow.ToString("O")); await add.ExecuteNonQueryAsync(ct); }
        await using (var update = c.CreateCommand()) { update.Transaction = (SqliteTransaction)tx; update.CommandText = "UPDATE invites SET accepted=1 WHERE id=$i"; update.Parameters.AddWithValue("$i", inviteId); await update.ExecuteNonQueryAsync(ct); }
        await tx.CommitAsync(ct); return new { householdId = Guid.Parse(hid), role, keyEnvelope = Convert.ToBase64String(key) };
    }
    public async Task RemoveMemberAsync(Guid household, Guid member, CancellationToken ct) { await using var c = Open(); await c.OpenAsync(ct); await using var q = c.CreateCommand(); q.CommandText = "DELETE FROM memberships WHERE household_id=$h AND user_id=$u AND role!='admin'"; q.Parameters.AddWithValue("$h", household.ToString()); q.Parameters.AddWithValue("$u", member.ToString()); await q.ExecuteNonQueryAsync(ct); }
    public async Task<IReadOnlyList<RecordResponse>> GetRecordsAsync(Guid household, Guid user, string role, DateTimeOffset? since, CancellationToken ct)
    {
        var list = new List<RecordResponse>(); await using var c = Open(); await c.OpenAsync(ct); await using var q = c.CreateCommand(); q.CommandText = "SELECT id,audience,owner_id,allowed_members,ciphertext,revision,updated_at,deleted FROM records WHERE household_id=$h" + (since is null ? "" : " AND updated_at>$since") + " ORDER BY updated_at"; q.Parameters.AddWithValue("$h", household.ToString()); if (since is not null) q.Parameters.AddWithValue("$since", since.Value.ToString("O")); await using var r = await q.ExecuteReaderAsync(ct); while (await r.ReadAsync(ct)) { var owner = r.IsDBNull(2) ? (Guid?)null : Guid.Parse(r.GetString(2)); var allowed = JsonSerializer.Deserialize<List<Guid>>(r.GetString(3)) ?? []; if (!RecordPolicy.CanRead(r.GetString(1), owner, allowed, user, role)) continue; list.Add(new(Guid.Parse(r.GetString(0)), r.GetString(1), owner, allowed, Convert.ToBase64String((byte[])r[4]), r.GetInt64(5), DateTimeOffset.Parse(r.GetString(6)), r.GetInt64(7) == 1)); } return list;
    }
    public async Task<RecordResponse?> CreateRecordAsync(Guid household, SaveRecordRequest request, Guid actor, CancellationToken ct)
    {
        try { await using var c = Open(); await c.OpenAsync(ct); await using var q = c.CreateCommand(); q.CommandText = "INSERT INTO records(household_id,id,audience,owner_id,allowed_members,ciphertext,revision,updated_at) VALUES($h,$i,$a,$o,$m,$c,1,$t)"; BindRecord(q, household, request); q.Parameters.AddWithValue("$t", DateTimeOffset.UtcNow.ToString("O")); await q.ExecuteNonQueryAsync(ct); return new(request.RecordId, request.Audience, request.OwnerId, request.AllowedMemberIds, request.Ciphertext, 1, DateTimeOffset.UtcNow, false); } catch (SqliteException) { return null; }
    }
    public async Task<RecordResponse?> UpdateRecordAsync(Guid household, Guid id, UpdateRecordRequest request, Guid actor, string role, CancellationToken ct)
    {
        await using var c = Open(); await c.OpenAsync(ct); await using var tx = await c.BeginTransactionAsync(ct);
        await using var current = c.CreateCommand(); current.Transaction = (SqliteTransaction)tx; current.CommandText = "SELECT audience,owner_id,allowed_members FROM records WHERE household_id=$h AND id=$i AND deleted=0"; current.Parameters.AddWithValue("$h", household.ToString()); current.Parameters.AddWithValue("$i", id.ToString());
        await using var reader = await current.ExecuteReaderAsync(ct); if (!await reader.ReadAsync(ct)) return null;
        var oldAudience = reader.GetString(0); var oldOwner = reader.IsDBNull(1) ? (Guid?)null : Guid.Parse(reader.GetString(1)); var oldAllowed = JsonSerializer.Deserialize<List<Guid>>(reader.GetString(2)) ?? []; await reader.DisposeAsync();
        var newRecord = request.Record;
        var sameScope = oldAudience == newRecord.Audience && oldOwner == newRecord.OwnerId && oldAllowed.OrderBy(x => x).SequenceEqual(newRecord.AllowedMemberIds.OrderBy(x => x));
        if (!RecordPolicy.CanWrite(oldAudience, oldOwner, oldAllowed, actor, role) || !sameScope || !RecordPolicy.CanWrite(newRecord.Audience, newRecord.OwnerId, newRecord.AllowedMemberIds, actor, role)) return null;
        var now = DateTimeOffset.UtcNow; await using var q = c.CreateCommand(); q.Transaction = (SqliteTransaction)tx; q.CommandText = "UPDATE records SET ciphertext=$c,revision=revision+1,updated_at=$t WHERE household_id=$h AND id=$i AND revision=$v AND deleted=0"; q.Parameters.AddWithValue("$c", Convert.FromBase64String(newRecord.Ciphertext)); q.Parameters.AddWithValue("$t", now.ToString("O")); q.Parameters.AddWithValue("$h", household.ToString()); q.Parameters.AddWithValue("$i", id.ToString()); q.Parameters.AddWithValue("$v", request.ExpectedRevision); if (await q.ExecuteNonQueryAsync(ct) != 1) return null;
        await tx.CommitAsync(ct); return new(id, newRecord.Audience, newRecord.OwnerId, newRecord.AllowedMemberIds, newRecord.Ciphertext, request.ExpectedRevision + 1, now, false);
    }
    public async Task<bool> TombstoneRecordAsync(Guid household, Guid id, Guid actor, string role, CancellationToken ct)
    {
        await using var c = Open(); await c.OpenAsync(ct); await using var get = c.CreateCommand(); get.CommandText = "SELECT audience,owner_id,allowed_members FROM records WHERE household_id=$h AND id=$i AND deleted=0"; get.Parameters.AddWithValue("$h", household.ToString()); get.Parameters.AddWithValue("$i", id.ToString()); await using var r = await get.ExecuteReaderAsync(ct); if (!await r.ReadAsync(ct)) return false; var audience = r.GetString(0); var owner = r.IsDBNull(1) ? (Guid?)null : Guid.Parse(r.GetString(1)); var allowed = JsonSerializer.Deserialize<List<Guid>>(r.GetString(2)) ?? []; await r.DisposeAsync(); if (!RecordPolicy.CanWrite(audience, owner, allowed, actor, role)) return false; await using var d = c.CreateCommand(); d.CommandText = "UPDATE records SET deleted=1,revision=revision+1,updated_at=$t WHERE household_id=$h AND id=$i"; d.Parameters.AddWithValue("$t", DateTimeOffset.UtcNow.ToString("O")); d.Parameters.AddWithValue("$h", household.ToString()); d.Parameters.AddWithValue("$i", id.ToString()); return await d.ExecuteNonQueryAsync(ct) == 1;
    }
    private static void BindRecord(SqliteCommand q, Guid household, SaveRecordRequest request) { q.Parameters.AddWithValue("$h", household.ToString()); q.Parameters.AddWithValue("$i", request.RecordId.ToString()); q.Parameters.AddWithValue("$a", request.Audience); q.Parameters.AddWithValue("$o", request.OwnerId?.ToString() ?? (object)DBNull.Value); q.Parameters.AddWithValue("$m", JsonSerializer.Serialize(request.AllowedMemberIds)); q.Parameters.AddWithValue("$c", Convert.FromBase64String(request.Ciphertext)); }
}

sealed record UserRow(Guid Id, string Name, byte[] Salt, byte[] PasswordHash, bool Verified, byte[]? CodeHash, DateTimeOffset CodeExpires, byte[]? ResetHash, DateTimeOffset ResetExpires);
sealed record RecordResponse(Guid RecordId, string Audience, Guid? OwnerId, IReadOnlyList<Guid> AllowedMemberIds, string Ciphertext, long Revision, DateTimeOffset UpdatedAt, bool Deleted);
