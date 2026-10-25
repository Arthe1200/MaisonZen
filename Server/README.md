# Serveur familial MaisonZen

L’API est conçue pour tourner sur le PC familial. Les comptes utilisent un code de vérification et un code de récupération de mot de passe par e-mail. SQLite conserve les comptes, les foyers, les droits, les enveloppes de clés, les sauvegardes de récupération chiffrées et les fiches de foyer chiffrées côté application.

## Lancer en développement sur le réseau local

Installer le SDK .NET 10, puis depuis ce dossier dans PowerShell :

```powershell
$env:ASPNETCORE_ENVIRONMENT = 'Development'
dotnet run --urls 'http://0.0.0.0:5080'
```

Sans SMTP, l’API de développement renvoie le code de vérification dans sa réponse, pour permettre l’essai. Les secrets de développement sont fixes : ne démarre jamais un serveur accessible depuis internet avec `ASPNETCORE_ENVIRONMENT=Development`.

Sur le même réseau Wi-Fi, configure l’application iOS avec l’adresse IP locale du PC, par exemple `http://192.168.1.25:5080`. Autorise le port choisi dans le pare-feu Windows uniquement sur le profil de réseau privé. Cette configuration HTTP sert aux essais locaux de développement.

## Configuration de production

La production refuse toutes les requêtes HTTP. Configure un certificat TLS et n’écoute que sur HTTPS. Exemple de variables à adapter au compte Windows qui exécute le service :

```powershell
$env:ASPNETCORE_ENVIRONMENT = 'Production'
$env:ASPNETCORE_URLS = 'https://0.0.0.0:5443'
$env:Kestrel__Certificates__Default__Path = 'C:\MaisonZen\certificat.pfx'
$env:Kestrel__Certificates__Default__Password = '<mot de passe du certificat>'
$env:MAISONZEN_DATA_KEY = '<secret aléatoire base64 de 32 octets>'
$env:MAISONZEN_TOKEN_KEY = '<secret aléatoire base64 de 32 octets ou plus>'
$env:DatabasePath = 'C:\MaisonZen\data\maisonzen.db'
dotnet .\bin\Release\net10.0\MaisonZen.Server.dll
```

Génère les deux secrets avec un générateur cryptographique et conserve-les hors du dépôt et séparément des sauvegardes SQLite. Si tu les perds, les e-mails/noms chiffrés et les sessions du serveur ne pourront plus être traités. Si tu les exposes, renouvelle-les en tenant compte de la migration des données.

Pour activer la vérification par e-mail, configure les paramètres `Smtp__Host`, `Smtp__Port`, `Smtp__User`, `Smtp__Password` et `Smtp__From`. Stocke ces valeurs dans l’environnement ou dans le gestionnaire de secrets du système, jamais dans le dépôt.

Pour les appels à travers internet ou des routeurs restrictifs, installe un relais TURN (par exemple coturn) et configure `Turn__Urls__0` avec son URL `turn:`/`turns:` ainsi que `MAISONZEN_TURN_SECRET` avec le secret partagé par le relais. Sans TURN, les appels peuvent fonctionner sur le même réseau ou certains réseaux, mais pas sur toutes les connexions.

L’accès hors du Wi-Fi familial doit passer par un VPN privé ou une configuration réseau HTTPS soigneusement sécurisée. Le port HTTPS ne suffit pas à fournir des notifications Apple en arrière-plan; celles-ci nécessitent APNs, qui n’est pas intégré à cette version.

## Dépendances externes

- La recherche de produits envoie le code-barres seul à l’API Open Food Facts via le serveur familial. Si cette base est inaccessible ou ne reconnaît pas le produit, la saisie manuelle reste disponible.
- Le SMTP est utilisé uniquement pour les codes de compte et de réinitialisation.
- TURN est optionnel et ne sert qu’au transport des appels lorsque les appareils ne peuvent pas établir une liaison directe.

## Vérification locale

```powershell
dotnet build
.\run-verification.ps1
```

Le scénario crée une base temporaire et vérifie l’inscription, la validation d’adresse, la récupération de compte et des clés, les rôles adulte/enfant/locataire, les invitations, les droits de lecture et de suppression, les conflits de révision, les tombstones et la réponse TURN.
