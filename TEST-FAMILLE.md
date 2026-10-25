# Test familial MaisonZen

Période visée : deux à trois mois. Faire les scénarios sur les vrais comptes et appareils de la famille, sans saisir de données financières ou personnelles sensibles avant que le serveur HTTPS et les droits d’accès aient été vérifiés.

## Parcours à vérifier

- Créer un compte, recevoir le code e-mail, se déconnecter, se reconnecter et réinitialiser le mot de passe.
- Créer un foyer, inviter un adulte, un enfant et un locataire; vérifier qui peut inviter et retirer des membres.
- Créer une dépense personnelle pour un enfant, une dépense personnelle pour un parent et une dépense du foyer. Vérifier sur chaque compte qui peut voir, modifier et supprimer chaque ligne.
- Ajouter un abonnement privé puis un abonnement adulte du foyer. Vérifier fréquence, prochaine date, personnes concernées et notification.
- Créer un rappel personnel, un rappel adressé à une personne et un rappel du foyer; tester répétition, heure et silence.
- Créer une tâche et un devoir attribué, les terminer, puis contrôler les notifications et la synchronisation sur les autres appareils.
- Scanner un code-barres reconnu et un code inconnu; vérifier la saisie manuelle, la date de péremption et le rappel.
- Filtrer les recettes par allergies et régime, consulter les ingrédients et ajouter un repas au planning.
- Ajouter un événement et vérifier la semaine affichée sur plusieurs appareils.
- Envoyer un message familial puis un message ciblé; vérifier que seuls les participants le voient dans l’application.
- Passer un appel audio entre deux appareils sur le Wi-Fi puis depuis des réseaux différents; tester mode muet, refus et raccrochage.
- Activer le dashboard sur un seul iPad, déplacer/redimensionner les widgets, changer le graphique et vérifier que l’iPhone reste en interface normale.
- Créer le code de récupération, restaurer les clés sur un nouvel appareil et vérifier l’accès au foyer.

## Fiche d’observation à recopier

```text
Date et heure :
Appareil et version iOS :
Réseau utilisé :
Compte / rôle concerné :
Parcours effectué :
Résultat attendu :
Résultat observé :
Problème reproductible (oui/non) :
Importance (bloquant / gênant / léger) :
Capture ou étapes pour reproduire :
```

## Critères de sortie du test

- Aucun membre ne voit les dépenses interdites par son rôle dans l’application.
- Les invitations et suppressions respectent le rôle administrateur.
- Les rappels et changements arrivent sur les appareils concernés après synchronisation.
- Les invitations, messages, ajouts au frigo, modifications et suppressions ne perdent pas de données lors d’éditions simultanées.
- Appels audio confirmés sur les réseaux réellement utilisés par la famille.
- Les limites connues (push en arrière-plan, configuration TURN et renouvellement de signature Apple) sont comprises par les testeurs.

Ne pas inscrire ici de mot de passe, de code d’invitation actif, de code de récupération ou de donnée médicale réelle.
