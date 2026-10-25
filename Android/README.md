# Application Android

Le dossier Android est réservé à une application native séparée. Aucune application Android n’est encore implémentée ici. Le contrat de l’API familiale est documenté et déjà utilisé par l’application iOS; le client Android devra appliquer les mêmes règles de rôles, de chiffrement côté appareil, de synchronisation et de notifications.

Le futur client devra suivre le protocole cryptographique commun : AES-GCM pour les fiches, enveloppes de clés ECDH P-256, clé générale du foyer, clé adulte remise uniquement aux adultes/administrateurs, clé personnelle dérivée de la clé privée du compte et sauvegarde de récupération chiffrée compatible avec iOS. L’ordre prévu est de valider d’abord les flux iOS et le serveur avec la famille, puis de créer ce client Android.
