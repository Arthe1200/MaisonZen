# MaisonZen

MaisonZen is a free family organizer for iPhone and iPad, backed by a server hosted at home. The current workspace contains the native iOS app source and a .NET server. The Android directory is reserved for the separate Android app.

## Workspace

- [Product plan and requirements](PLAN-MAISONZEN.md)
- [Family test checklist and feedback sheet](TEST-FAMILLE.md)
- [iOS build and family test notes](iOS/README.md)
- [Home server setup](Server/README.md)
- [Android project status](Android/README.md)
- [GitHub Actions iOS workflow](.github/workflows/ios-build.yml)
- Original logo: `assets/maisonzen-logo.svg`

## Current verification

The server builds with .NET 10, and its HTTP integration scenario passes. The iOS project is prepared for Xcode, but this workspace was produced on Windows, where Xcode and Apple SDKs are unavailable. It still needs a Mac build, code signing, and hands-on testing on the family's iPhones and iPads before it can be called a working Apple test build.

On Windows, verify the server from PowerShell:

```powershell
cd .\Server
dotnet build
.\run-verification.ps1
```

The script starts an isolated development server with a temporary database, checks account flows and household access rules, then removes its own temporary test directory.

## Privacy summary

Family records are encrypted on Apple devices before synchronization. The server stores encrypted record contents and applies access rules using role and audience metadata. It separately encrypts account email and profile names at rest so it can authenticate users and show household members. The server can decrypt those account fields; household record contents are not decrypted by the server. A barcode lookup sends only the barcode through the home server to Open Food Facts. See the plan for remaining security boundaries and the current feature status.
