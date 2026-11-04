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

## Ce que le conteneur apporte

- Il borne la coupure si le Gratuitous ARP ne fait pas son effet : 11 s au lieu d'un black hole sans fin. Ce comportement du routeur est mesuré ici, sans que nous ayons vérifié s'il est documenté, et le conteneur évite d'en dépendre seul.
- Il garde l'IPAM juste pour la console, l'API et les sorties qui la lisent.

Il ne réduit pas la coupure nominale. Une écriture fausse dans l'IPAM coupe toujours le hub jusqu'à la prochaine écriture : le conteneur écarte les appels périmés, pas un déplacement manuel vers le mauvais nœud.

## Comparaison avec les SDN Connectors

Sur AWS et Azure, les connecteurs Fortinet déplacent par API ce que le réseau rattache à une carte : IP publique, routes vers une interface, IP privée flottante sur Azure. Notre conteneur fait le même geste sur l'IPAM.

Deux candidats ont été testés sur Scaleway.

Une route VPC avec `nexthop_resource_id` désigne une carte. Route `198.18.0.0/24` vers `port5` de fw1, ping depuis `hub-obs` : après la bascule, les trames restent sur fw1, devenu secondaire, malgré les Gratuitous ARP. Seule la mise à jour de la route par API les déplace, en moins de 2 s. L'API exige `nexthop_private_network_id` avec `nexthop_resource_id`, à la création comme à la mise à jour. Cette logique de connecteur serait donc nécessaire à toute route de ce type. Le déploiement n'en utilise pas : ses règles visent la VIP, résolue par IP.

Une IP publique flexible est zonale : l'IP de `fr-par-1` ne s'attache pas à fw2 en `fr-par-2`, l'API répond que la ressource n'existe pas. Nos nœuds étant dans deux zones, ce déplacement est impossible. Deux nœuds dans une même zone n'ont pas été testés.

## Ce qui n'est pas prouvé

- La perte brutale d'une zone : la carte existait encore dans tous les tests. Une Instance arrêtée proprement n'est pas une panne.
- Un appel tardif naturel vers un secondaire : l'envoi retardé est observé, mais vers un nœud alors primaire. Le refus est prouvé sur un appel rejoué.
- Pourquoi l'appel du secondaire reste en attente, et pourquoi une seule des trois actions part.
- La variante `hub-spoke-single-project` et Interlink. Interlink évite la VIP et demande un lien partenaire.
- Une exposition complète du hub avec Edge Services : le test s'arrête au Load Balancer.
- La tenue au-delà de 3 h.
- La stabilité de ce comportement du routeur dans le temps : nous n'avons pas vérifié si Scaleway le documente.
