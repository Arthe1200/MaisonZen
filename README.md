# MaisonZen

MaisonZen est une application gratuite d’organisation familiale pour iPhone, iPad et Android, reliée à un serveur hébergé sur le PC de la maison. Elle permet de gérer les foyers, les abonnements, les dépenses, les rappels, les tâches, le planning, le frigo, les recettes et les échanges familiaux.

## Installer l’application iOS

1. Ouvrir le dépôt [MaisonZen sur GitHub](https://github.com/Arthe1200/MaisonZen).
2. Aller dans **Actions**, puis ouvrir le dernier workflow **MaisonZen iOS build** terminé avec succès.
3. Télécharger l’artefact `MaisonZen-iOS-sideload-v2`.
4. Décompresser l’artefact et récupérer `MaisonZen-sideload.ipa`.
5. Installer l’IPA sur l’iPhone avec iPASide, Sideloadly ou LiveContainer.
6. Sur l’iPhone, activer **Réglages → Confidentialité et sécurité → Mode développeur**.
7. Si l’application est installée directement, faire confiance au profil dans **Réglages → Général → VPN et gestion de l’appareil**.

LiveContainer peut être utilisé pour les tests si l’installation directe ferme l’application. Dans ce cas, lancer MaisonZen depuis LiveContainer.

## Installer l’application Android

1. Ouvrir **Actions → MaisonZen Android build** dans le dépôt GitHub.
2. Lancer **Run workflow** si aucune compilation récente n’est disponible.
3. Télécharger l’artefact `MaisonZen-Android-debug` de l’exécution terminée avec succès et extraire `app-debug.apk`.
4. Installer l’APK sur le téléphone avec Android Debug Bridge (`adb install -r app-debug.apk`) ou en ouvrant le fichier depuis le téléphone.
5. Saisir dans Maison Zen l’adresse IPv4 du PC et le port `5080`.

Les détails d’installation, de configuration du serveur et de récupération des données sont dans [le guide Android](Android/README.md).

## Lancer le serveur sur Windows

Le serveur est nécessaire pour la connexion, les comptes, les foyers et la synchronisation entre appareils. Installer le SDK .NET 10, puis ouvrir PowerShell dans le dossier `Server` :

```powershell
cd "C:\chemin\vers\MaisonZen\Server"
$env:ASPNETCORE_ENVIRONMENT = "Development"
dotnet run --urls "http://0.0.0.0:5080"
```

Laisser cette fenêtre PowerShell ouverte pendant les tests.

Pour connaître l’adresse IP du PC :

```powershell
ipconfig
```

Dans l’application, saisir l’adresse IPv4 du PC suivie du port `5080`, par exemple :

```text
http://192.168.1.168:5080
```

L’iPhone et le PC doivent être connectés au même Wi-Fi. Le pare-feu Windows doit autoriser le port `5080` sur le réseau privé.

## Utiliser MaisonZen

1. Créer un compte avec une adresse e-mail et un mot de passe.
2. Créer un foyer ou rejoindre un foyer avec un code d’invitation.
3. L’administrateur invite les autres membres et attribue leur rôle : adulte, enfant ou locataire.
4. Utiliser l’accueil pour accéder aux abonnements, dépenses, rappels, tâches, planning, frigo, recettes et messages.
5. Les dépenses personnelles restent privées ; les dépenses du foyer sont réservées aux adultes.
6. Les rappels peuvent être individuels ou destinés à tout le foyer, avec répétition et mode silencieux.
7. Les données du foyer sont chiffrées sur les appareils avant leur synchronisation avec le serveur.

Le serveur doit être démarré avant la connexion ou la synchronisation. Pour arrêter le serveur, revenir dans PowerShell et appuyer sur `Ctrl+C`.

## Workspace

- [Product plan and requirements](PLAN-MAISONZEN.md)
- [Family test checklist and feedback sheet](TEST-FAMILLE.md)
- [iOS build and family test notes](iOS/README.md)
- [Home server setup](Server/README.md)
- [Android installation and user guide](Android/README.md)
- [GitHub Actions Android workflow](.github/workflows/android-build.yml)
- [GitHub Actions iOS workflow](.github/workflows/ios-build.yml)
- Original logo: `assets/maisonzen-logo.svg`

## Vérification du serveur

Le serveur se construit avec .NET 10 et son scénario d’intégration passe. Pour vérifier le serveur depuis PowerShell :

```powershell
cd .\Server
dotnet build
.\run-verification.ps1
```

The script starts an isolated development server with a temporary database, checks account flows and household access rules, then removes its own temporary test directory.

## Privacy summary

Family records are encrypted on Apple and Android devices before synchronization. The server stores encrypted record contents and applies access rules using role and audience metadata. It separately encrypts account email and profile names at rest so it can authenticate users and show household members. The server can decrypt those account fields; household record contents are not decrypted by the server. A barcode lookup sends only the barcode through the home server to Open Food Facts. See the platform guides for features that are still in progress.
