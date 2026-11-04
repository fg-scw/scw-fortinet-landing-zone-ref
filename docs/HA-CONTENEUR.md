# HA FortiGate et conteneur de bascule : ce qui est prouvé

Mesures des 3 et 4 novembre 2026 sur le déploiement `hub-spoke-multi-project` : FortiOS 8.0.2, fw1 en `fr-par-1`, fw2 en `fr-par-2`, FGCP actif-passif. Le trafic part d'une VM du spoke HR vers une VM du spoke genomic (est-ouest) et vers `1.1.1.1` (Internet), un ping toutes les 100 ms.

Le routeur du VPC envoie le trafic du hub vers la dernière MAC qu'on lui a indiquée, soit par un Gratuitous ARP, soit par une écriture dans l'IPAM. FGCP assure la bascule rapide par le Gratuitous ARP. Le conteneur fournit un second chemin indépendant, plus lent, et garde l'IPAM juste. Une écriture fausse dans l'IPAM coupe le trafic du hub.

## Comment le routeur apprend la MAC

Le routeur n'interroge jamais la VIP : 0 requête ARP de sa part pour `172.16.0.10` en 6 min de capture. Deux événements déplacent son next hop.

| Événement | Résultat mesuré |
|---|---|
| Gratuitous ARP broadcast, IPAM inchangée | le trafic change de nœud en 0,1 s environ (2 bascules) |
| Écriture IPAM vers le vrai primaire, Gratuitous ARP coupé | fin d'un black hole de 328 s, moins de 0,1 s après l'écriture |
| Écriture IPAM vers le secondaire, cluster sain | black hole immédiat, 40,6 s, jusqu'au retour de l'IPAM |

Les ARP unicast du nouveau primaire vers le routeur ne suffisent pas : 11 échanges pendant le black hole, sans effet.

Ces événements-là ne déplacent pas le next hop, IPAM périmée sur fw2 et trafic sur fw1 :

- modification d'une règle VPC (description, source réduite puis rétablie), nouvelle règle, avec fw2 en marche puis arrêtée. Pendant les 25,5 s où la plage du test sort de la règle, le trafic est coupé comme prévu, puis il revient sur fw1. La nouvelle règle n'a pas forcément été celle appliquée ;
- ARP frais d'un nouveau client : `hub-obs` a vidé son cache trois fois, fw1 répond. Personne ne répond à partir de l'IPAM ;
- retour de l'Instance fw2 : 0 ping perdu.

La VIP Egress est différente : ses clients, les Public Gateways, font de l'ARP toutes les 30 s environ. Une IPAM fausse pendant 45 s n'a coûté aucun ping.

## Ce que fait FortiOS

1. Les deux nœuds échangent un heartbeat sur `port4`. Après 20 battements manqués à 200 ms, soit 4 s, le secondaire se déclare primaire.
2. Les deux nœuds portent la même IP sur `port3`, et seul le primaire répond aux ARP, avec sa propre MAC.
3. À chaque élection, le primaire envoie 60 Gratuitous ARP à 1 par seconde sur les deux VIP. Il le fait aussi quand il reste primaire : au retour de fw2, fw1 a réémis ses 60 Gratuitous ARP.
4. Le secondaire ne transmet pas de données et laisse tomber les trames qui lui arrivent. Son propre trafic sort par le primaire.

## Ce que fait le conteneur

1. Le changement de rôle écrit l'événement 37892 `ha_role=primary`, ce qui lance `lz-ipam-follow`.
2. Environ 2,5 s après la bascule, le nouveau primaire appelle le conteneur sur le réseau hub et envoie son nom d'hôte avec l'heure de l'événement.
3. Le conteneur déplace les deux VIP vers ce nœud dans l'IPAM.

Chaque événement produit un seul appel : les répétitions à 10 et 30 s ne partent pas. Le rattrapage horaire ne vient que du primaire : le secondaire journalise son déclenchement à la minute 7, sans appel immédiat. Un appel resté en attente peut partir plus tard, si ce nœud devient primaire.

## Mesures de bascule

| Scénario | Gratuitous ARP | Conteneur | Coupure |
|---|---|---|---|
| Bascule commandée, 4 novembre (2 essais) | actif | désactivé | 0 à 2 pings perdus |
| Bascule commandée, 3 novembre (6 essais) | actif | actif | 0,3 à 3,4 s |
| Bascule commandée, 3 novembre | actif | désactivé | 3,2 s |
| Bascule commandée, 4 novembre (4 essais) | désactivé | actif | 10,5 à 11,1 s |
| Bascule commandée, 4 novembre | désactivé | désactivé | sans fin, 328 s avant écriture manuelle |
| Ports hub, egress et HA du primaire coupés | actif | désactivé | 5,1 s |
| Ports hub, egress et HA du primaire coupés | actif | actif | 5,9 s |
| `scw instance server stop` du primaire | actif | désactivé | 1,24 s |

`server stop` arrête FortiOS proprement : ce n'est pas une panne. La coupure des ports reste le test le plus proche d'une perte de zone.

## Load Balancer et VPN

Le VPN vient du module `hub`, avec deux tunnels et BGP vers une VM on-prem simulée sous strongSwan et FRR. Le Load Balancer a été créé à la main sur le réseau Egress, avec `10.96.8.2:8080` en backend : il suit le chemin d'une exposition du hub, sans Edge Services. Une requête toutes les 200 ms passe par lui.

| Scénario | Est-ouest | Internet | VPN | Requêtes LB perdues |
|---|---|---|---|---|
| Bascule fw1 vers fw2 | 0 s | 0 s | 0 s | 0 |
| Retour fw2 vers fw1 | 2,2 s | 2,2 s | 2,2 s | 1 |
| Gratuitous ARP désactivé, 2 bascules | 10,5 et 11,0 s | 10,6 et 11,0 s | 10,5 et 11,0 s | 22 et 20 |

Les trois chemins traversent le primaire et partagent le next hop de la VIP du hub : ils basculent ensemble.

Un premier essai a coupé le VPN 43 s sur fw2, par erreur de test : la route `192.168.0.0/16` manquait sur fw2. `router.static` ne se synchronise pas et la plateforme n'est lue qu'au premier démarrage : activer `vpn` sur un cluster déployé demande d'ajouter cette route sur chaque nœud.

## Pourquoi le conteneur met 11 s sans Gratuitous ARP

Le conteneur garde dans son cache ARP l'ancienne MAC de la VIP. Il répond donc à l'ancien primaire, qui ignore la réponse. La capture sur les deux nœuds donne, pour une bascule à T :

| Temps | Événement |
|---|---|
| T + 2,3 s | le nouveau primaire envoie son SYN depuis la VIP |
| T + 2,3 s | le SYN-ACK du conteneur part vers la MAC de l'ancien primaire et se perd |
| T + 3,3 et 5,4 s | SYN et SYN-ACK retransmis, toujours vers l'ancienne MAC |
| T + 7,3 s | le nouveau primaire envoie une requête ARP au conteneur, qui y répond |
| T + 9,5 s | le SYN-ACK suivant, après le backoff TCP, arrive enfin au nouveau primaire |
| T + 9,8 à 10,8 s | TLS, appel HTTP, déplacement dans l'IPAM |
| T + 10,5 s | le trafic repart |

Le second essai suit le même déroulé, avec une reprise à T + 11,0 s. Avec le Gratuitous ARP actif, le cache du conteneur est juste : le SYN-ACK arrive au nouveau primaire 2 ms après le SYN, et l'appel complet prend environ 1,5 s. Le délai vient donc du cache ARP du conteneur, pas du handler ni de l'API IPAM.

La correction de l'entrée par la requête ARP du nouveau primaire est déduite : aucun autre échange ARP n'apparaît sur ce nœud avant le premier SYN-ACK bien adressé, dans les deux essais.

## Appel tardif d'un ancien primaire

Le conteneur ne sait pas qui est primaire, et FortiOS peut envoyer un appel longtemps après son événement. Une capture en clair le montre : le rattrapage de 10:42:01 de fw2, alors secondaire, n'est parti qu'à 10:43:07, 16 s après que fw2 est devenu primaire. Un appel de ce genre qui nomme un nœud redevenu secondaire déplacerait l'IPAM vers lui.

L'effet a été mesuré avant le correctif : le primaire fw1 poste le nom `hub-fw2` par la même action et vers le même conteneur. L'IPAM passe sur fw2, le secondaire reçoit toutes les trames et les laisse tomber. Est-ouest, Internet, VPN et Load Balancer sont coupés 120,2 s, jusqu'au rattrapage de la minute 7.

Depuis le correctif, chaque appel porte l'heure de son événement (`%%log.eventtime%%`) et le conteneur refuse, en HTTP 409, un appel plus ancien que le dernier vu. Le même appel rejoué avec une heure ancienne a été refusé à 10:52 : le journal du conteneur indique `stale call`, l'IPAM ne bouge pas et aucun ping n'est perdu. Une bascule aller-retour avec le nouveau corps déplace toujours l'IPAM, en 5 s environ, sans trou de plus de 0,35 s dans les pings.

Le refus ne coupe rien : le Gratuitous ARP a déjà déplacé le trafic, et le rattrapage horaire remet l'IPAM d'aplomb. L'heure vit en mémoire : le conteneur passe à `max_scale = 1`, et un redémarrage l'oublie. Un appel tardif juste après un redémarrage passerait donc encore. Un appel récent qui nommerait le mauvais nœud passerait aussi : seuls les appels périmés sont refusés.

Cinq vraies bascules aller-retour rapides, à 1,3, 2, 2,5, 3 et 3,5 s d'intervalle, avant le correctif, n'avaient pas reproduit le problème : l'IPAM finit à chaque fois sur le vrai primaire.

## Tenue dans la durée

Fw2 est restée arrêtée 3 h 01, avec l'IPAM sur sa carte absente et les deux automations désactivées :

- est-ouest : 8 pings perdus sur 107 523, plus long trou 0,41 s ;
- Internet : 1 ping perdu sur 107 533 ;
- HTTPS : 718 réussites sur 719, l'échec à 06:23:27.

Toutes les pertes datent des 10 premières minutes. La cause de ces micro-coupures n'a pas été cherchée. Fw2 a rejoint le cluster 41 s après son démarrage, fw1 est resté primaire, et le retour de fw2 puis le déplacement de l'IPAM vers fw1 n'ont coûté aucun ping.

## Panne d'un firewall vue des spokes

Mesures du 4 novembre 2026 : `set status down` d'un coup sur les ports hub, egress et HA d'un nœud, réparation 90 à 370 s plus tard. La VM du spoke HR envoie 10 pings par seconde vers genomic et vers `1.1.1.1`, ouvre une connexion toutes les 200 ms environ vers les deux, et garde des sessions TCP longues : l'une vers genomic, les autres vers Internet. Deux sessions s'ouvrent aussi pendant la panne pour suivre ce qu'elles deviennent à la réparation. Sur les essais 1 à 7, une VM du réseau Pub du même spoke reçoit aussi un ping.

| Essai | Survivant | Ping est-ouest | Ping Internet | Seconde coupure Internet | TCP est-ouest | Silence TCP Internet | IPAM | Après réparation |
|---|---|---|---|---|---|---|---|---|
| 1 | fw2 | 4,3 s | 4,2 s | aucune | 6,7 s | 2,9 s | T+9 s | fw2 reste primaire |
| 2 | fw1 | 4,2 s | 4,2 s | 2,6 s | 6,8 s | 5 s puis 135 s | T+9 s | fw1 reste primaire |
| 3 | fw2 | 4,3 s | 7,4 s | 3,4 s | 6,7 s | 8 s puis 73 s | T+10 s | failback vers fw1 |
| 4 | fw2 | 4,2 s | 5,3 s | 2,3 s | 13,8 s | 7 s puis 121 s | T+9 à 11 s | fw2 reste primaire |
| 5 | fw1 | 5,1 s | 5,1 s | 2,5 s | 6,7 s | 104 s d'un seul tenant | T+9 s | fw1 reste primaire |
| 6 | fw2 | 4,2 s | 5,3 s | 2,8 s | 6,8 s | 6,8 s puis 117 s | T+10 s | fw2 reste primaire |
| 7 | fw1 | 5,2 s | 5,2 s | 2,3 s | 13,7 s | 2,8 s | T+9 s | fw1 reste primaire |
| 8 | fw2 | 4,1 s | 4,1 s | 3 s | 6,7 s | 3,4 s puis 81 s | T+9 s | fw2 reste primaire |
| 9 | fw1 | 7,2 s | 7,2 s | 2,5 s | 13,5 s | 7,5 s puis 62 s | T+8 s | fw1 reste primaire |
| 10, `failtime 20` | fw2 | 4,3 s | 7,4 s | 3 s | 6,7 s | 5 s puis 116 s | T+8 s | failback vers fw1 |
| 11, `snat-route-change enable` | fw2 | 4,3 s | 5,3 s | 3,2 s | 6,8 s | 6,3 s puis 115 s | T+10 s | failback vers fw1 |

Le trafic Pub ↔ Private du même spoke n'a perdu aucun paquet : il ne passe pas par le firewall. La panne et la réparation n'ont provoqué aucun reset. Les silences de 6,7 et 13,7 s des sessions est-ouest correspondent à des pas de retransmission TCP : le ping était revenu avant. Deux pannes du secondaire n'ont causé aucune perte, sur aucun flux.

### Silence des sessions Internet

Vers T+14 s, sur le nouveau primaire, les link monitors `pgw-a` et `pgw-b` retirent leurs routes en même temps, et les remettent 2 s plus tard. C'est la seconde coupure Internet : elle n'a lieu que sur le réseau Egress, alors que le trafic Internet passait.

La cause tient au nœud qui reprend le rôle. Un secondaire ne fait pas tourner ses link monitors et garde leur dernier état. Quand ses ports tombent, cet état passe à `dead` et y reste : nous l'avons vu encore figé 66 min plus tard. Quand il devient primaire, il repart de `dead`, ses compteurs ne bougent pas jusque vers T+14 s, puis cinq probes réussis le remettent `alive`.

| Survivant au moment de la panne | Essais | Seconde coupure |
|---|---|---|
| ports perdus depuis son dernier passage primaire | 12 | 12 |
| ports jamais perdus depuis | 3 | 0 |
| link monitors remis à zéro avant la panne | 3 | 0 |

Ces chiffres comptent les onze essais ci-dessus, les deux pertes de zone et cinq essais de contrôle. Les pannes de ce document s'enchaînent sur les mêmes nœuds, et c'est pour cela que presque toutes montrent la coupure : la première panne d'un cluster sain ne l'a pas eue (essai 1).

Les sessions Internet déjà ouvertes disparaissent alors du firewall. Sur l'essai 8, capturé des deux côtés :

| Temps | Événement |
|---|---|
| T+14 s | les routes par défaut tombent |
| T+16 s | la VM ne reçoit plus rien |
| T+19 à T+56 s | quatre retransmissions du serveur arrivent sur `port5`, aucune ne sort sur `port3` |
| vers T+30 et T+55 s | `diagnose sys session list` répond `total session: 0` |
| T+74 s | le keepalive TCP de curl, 60 s après la dernière donnée, sort par `port5` |
| vers T+81 s | la session existe de nouveau, recréée par ce paquet grâce au sloppy state |
| T+97 s | la retransmission suivante du serveur passe, le flux reprend et rattrape son retard |

Le silence dépend donc du keepalive du client :

| Keepalive du client | Silence mesuré |
|---|---|
| 5 s | 5 à 26 s |
| 60 s, le défaut de curl | 62 à 135 s |
| aucun | 28 s, 137 s, et deux sessions non reprises quand nous avons arrêté le test, 3 à 4 min plus tard |

Passer `failtime` à 20 (essai 10), activer `snat-route-change` (essai 11) ou porter `route-hold` à 40 s ne change rien. Désactiver puis réactiver les link monitors sur le secondaire efface l'état figé, sans perte pendant l'opération et sans désynchroniser le cluster. Trois pannes faites ensuite, dont deux avec un survivant réellement figé, une par sens, n'ont donné ni seconde coupure ni long silence : la session Internet longue a repris en 3,4 à 6,9 s, sans reset. La procédure est dans [OPERATIONS.md](OPERATIONS.md#après-la-réparation-dun-firewall).

L'essai 1 n'a pas eu de silence, faute de seconde coupure. L'essai 7, ralenti à 200 ko/s, a eu la coupure sans le silence, et nous n'expliquons pas cette différence.

Hors de toute bascule, à 12:56:18, le chemin Internet s'est coupé 3,5 s. Le link monitor `pgw-a` est passé `dead` 3 s plus tard et FortiOS a retiré la route vers cette Public Gateway. La session longue a reçu un reset du serveur. `pgw-a` est repassé `alive` 18 s après.

### Réconciliation

Le nœud revenu était in-sync au premier contrôle, 9 s après la remise des ports, à chaque essai. Les sessions ouvertes pendant la panne survivent à la réparation. Le rôle de primaire suit l'ordre FGCP, `override` étant désactivé :

- Si l'uptime FGCP des nœuds diffère de plus de 300 s (`ha-uptime-diff-margin`), le plus ancien est primaire. Le nœud revenu compte depuis son retour : sur un cluster stable, il revient donc secondaire, sans coupure.
- Sinon, la priorité tranche : fw1 (200) contre fw2 (100).

Ces deux règles concordent avec les quinze retours mesurés, et FortiOS indique son motif dans `get system ha status`. Les failbacks des essais 3, 10 et 11 viennent de la cadence du test : fw2 était revenu moins de 300 s avant fw1. Ils ont coûté au plus 1,2 s en est-ouest, 4,3 s vers Internet et 8,4 s aux sessions TCP, sans reset. fw1 y reprend le rôle avec ses link monitors figés, d'où une coupure Internet plus longue. Le conteneur a replacé l'IPAM en 5 à 6 s.

## Perte d'une zone, simulée

Scaleway ne permet pas d'éteindre une zone. Nous coupons les ports hub, egress et HA du firewall de la zone, et nous posons sur le survivant une entrée ARP statique vers une MAC inexistante pour la Public Gateway de cette zone. L'Instance et la Public Gateway restent allumées, et la VM genomic reste joignable bien qu'elle soit en `fr-par-1`. Un essai par zone, le primaire étant chaque fois dans la zone perdue.

| Mesure | `fr-par-1` perdue : fw1 et PGW a, préférée | `fr-par-2` perdue : fw2 et PGW b, de secours |
|---|---|---|
| Ping est-ouest | 5,1 s | 5 s |
| Ping Internet | 16,4 s | 5 s, puis 3,1 s |
| Nouvelles connexions est-ouest | 5 requêtes en échec | 4 requêtes en échec |
| Nouvelles connexions Internet | 14 requêtes en échec | 8 requêtes en échec |
| Session TCP est-ouest | conservée, 6,7 s | conservée, 6,7 s |
| Sessions TCP Internet | 3 sur 3 coupées entre T+20 et T+32 s | conservées, silence de 6 à 137 s |
| VIP dans l'IPAM | T+10 s | T+8 s |
| IP publique de sortie | change | ne change pas |
| Primaire après retour | fw2 | fw1 |

En `fr-par-1`, le link monitor `pgw-a` déclare la Public Gateway morte, FortiOS bascule la route par défaut vers PGW b entre T+8 et T+15 s, et Internet revient à T+16,4 s. Les sessions déjà ouvertes meurent, car leur IP publique a changé.

En `fr-par-2`, la seconde coupure et le silence viennent des link monitors figés de fw1, qui sortait de la perte de `fr-par-1`.

Le retour n'a fait perdre aucun ping. En `fr-par-1`, la route revient vers PGW a et la session ouverte pendant la perte, passée par PGW b, a été coupée quelques secondes plus tard. Le conteneur a fonctionné dans les deux cas, car rien dans ce test ne touchait son instance.

## Ce que le conteneur apporte

On le conserve comme assurance. Dans les onze pannes ci-dessus, le Gratuitous ARP a rétabli le trafic entre T+4 et T+7 s et le conteneur a écrit l'IPAM entre T+8 et T+11 s : il n'a rien raccourci. Sa valeur tient aux cas où ce premier chemin manque.

- Il borne la coupure si le Gratuitous ARP ne fait pas son effet : 11 s au lieu d'un black hole sans fin. Ce comportement du routeur est mesuré ici, sans que nous ayons vérifié s'il est documenté, et le conteneur évite d'en dépendre seul.
- Il garde l'IPAM juste pour la console, l'API et les sorties qui la lisent.

Il ne réduit pas la coupure nominale. Une écriture fausse dans l'IPAM coupe toujours le hub jusqu'à la prochaine écriture : le conteneur écarte les appels périmés, pas un déplacement manuel vers le mauvais nœud.

Aucune des 18 pannes provoquées avec le Gratuitous ARP actif n'a eu besoin du conteneur : le risque qu'il couvre n'a été observé qu'en désactivant nous-mêmes le Gratuitous ARP. Nous n'avons pas vérifié si Scaleway garantit que le routeur suit le Gratuitous ARP. Si c'est garanti, le conteneur ne sert plus qu'à garder l'IPAM juste. Sinon, il est le seul chemin qui repose sur une API publique.

## Comparaison avec les SDN Connectors

Sur AWS et Azure, les connecteurs Fortinet déplacent par API ce que le réseau rattache à une carte : IP publique, routes vers une interface, IP privée flottante sur Azure. Notre conteneur fait le même geste sur l'IPAM.

Deux candidats ont été testés sur Scaleway.

Une route VPC avec `nexthop_resource_id` désigne une carte. Route `198.18.0.0/24` vers `port5` de fw1, ping depuis `hub-obs` : après la bascule, les trames restent sur fw1, devenu secondaire, malgré les Gratuitous ARP. Seule la mise à jour de la route par API les déplace, en moins de 2 s. L'API exige `nexthop_private_network_id` avec `nexthop_resource_id`, à la création comme à la mise à jour. Cette logique de connecteur serait donc nécessaire à toute route de ce type. Le déploiement n'en utilise pas : ses règles visent la VIP, résolue par IP.

Une IP publique flexible est zonale : l'IP de `fr-par-1` ne s'attache pas à fw2 en `fr-par-2`, l'API répond que la ressource n'existe pas. Nos nœuds étant dans deux zones, ce déplacement est impossible. Deux nœuds dans une même zone n'ont pas été testés.

## Ce qui n'est pas prouvé

- La perte réelle d'une zone : le test la simule, les cartes et les Instances existaient encore. Une Instance arrêtée proprement n'est pas une panne. Le conteneur n'a pas perdu son instance.
- Pourquoi les routes tombent 10 s après l'élection : `route-hold` n'y est pour rien, `route-ttl` n'a pas été testé.
- Une remise à zéro automatique des link monitors. La procédure reste manuelle, et le secondaire retient ses appels de stitch.
- Un appel tardif naturel vers un secondaire : l'envoi retardé est observé, mais vers un nœud alors primaire. Le refus est prouvé sur un appel rejoué.
- Pourquoi l'appel du secondaire reste en attente, et pourquoi une seule des trois actions part.
- La variante `hub-spoke-single-project` et Interlink. Interlink évite la VIP et demande un lien partenaire.
- Une exposition complète du hub avec Edge Services : le test s'arrête au Load Balancer.
- La tenue au-delà de 3 h.
- La stabilité de ce comportement du routeur dans le temps : nous n'avons pas vérifié si Scaleway le documente.
