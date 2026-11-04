# Exploitation

Après chaque modification : `terraform plan`, relecture, puis `terraform apply`. La politique du firewall est poussée à chaud. Un réglage de plateforme (interfaces, HA, passerelles, syslog, licence, clés `admin`) n'atteint un nœud qu'à sa création : il faut le reconstruire.

## Ajouter un spoke

Ajoutez une entrée à `spokes` dans `terraform.tfvars`, avec un `index` unique entre 0 et 1023, puis appliquez. Le firewall n'est pas modifié. Ne changez jamais l'`index` d'un spoke existant : il fixe ses adresses.

Dans la même entrée, `nacl_inbound` ouvre un flux entrant et `hybrid_bypass = true` relie le spoke à Interlink (il faut alors `interlink`). Toute exposition passe par Edge Services : `edge_services_plan` est requis dès que `endpoints` en contient une.

## Retirer un spoke

Supprimez d'abord ce qui est attaché à ses Private Networks (instances, LB, bases), puis retirez ses expositions de `endpoints` et son entrée de `spokes`, et appliquez.

## Changer la politique du firewall

Modifiez `policy.yaml` (format et exemples dans `policy.yaml.example`), puis appliquez. Les règles sont poussées sur le primaire, qui synchronise le secondaire, sans redémarrage. Un réglage fait dans le WebUI est écrasé au push suivant. Aucun flux on-prem n'est ouvert par défaut : déclarez-les avec l'alias `ONPREM_VPN`.

## Reconstruire un firewall

Un changement de plateforme ou de version passe par une reconstruction. Le plan l'annonce par une mise à jour de `module.hub.terraform_data.fw_config`. Reconstruisez un nœud par apply, le secondaire d'abord :

```bash
ssh -J <bastion> admin@<ip-mgmt> 'get system ha status'                     # qui est primaire ?
terraform apply -replace='module.hub.terraform_data.fw_generation["fw2"]'   # le secondaire
# sur le primaire, en SSH interactif : execute ha failover set 1   (confirmer par y)
terraform apply -replace='module.hub.terraform_data.fw_generation["fw1"]'   # l'ancien primaire
```

<img alt="Mise à jour en production : on reconstruit le secondaire, on bascule vers lui, puis on reconstruit l'ancien primaire, qui revient en secondaire." src="lz-rebuild.svg">

Un nœud reconstruit revient en secondaire et le cluster ne rebascule pas. Il peut rester *out-of-sync* 5 à 6 minutes, le temps que le primaire mette à jour ses objets FortiGuard : attendez `in-sync` avant l'étape suivante. Pour changer de version, remplacez le `snapshot_id` d'un nœud, puis de l'autre, dans le même ordre.

## Faire tourner les clés de bascule

```bash
terraform apply -replace='module.hub.scaleway_iam_api_key.fw_invoke'    # clé du firewall
terraform apply -replace='module.hub.scaleway_iam_api_key.ipam_follow'  # clé du conteneur
```

Aucun nœud n'est reconstruit. Si une bascule échoue entre-temps, déplacez les VIP avec la ligne du primaire de `terraform output -json failover_commands`.

## Accès direct aux firewalls

Avec `admin_direct_access = true`, chaque Public Gateway redirige ses ports publics vers le nœud de sa zone : `ssh -p 2222 admin@<ip-pgw>` et `https://<ip-pgw>:8443`, donnés par la sortie `access` (`direct_ssh`, `direct_webui`). Seules les adresses de `admin_cidrs` passent. L'option s'active et se retire par un apply, sans reconstruire les nœuds. Le WebUI présente le certificat auto-signé du FortiGate.

## Journaux

Avec `observability = true`, une petite VM du réseau Egress reçoit le syslog des firewalls (RFC 5424, port 514 en UDP et TCP) et Grafana Alloy le pousse dans Cockpit. Le relais n'a ni HA ni TLS : s'il tombe, les firewalls gardent leurs journaux en local. Si le client a déjà un SIEM, laissez `observability = false` et mettez son collecteur dans `firewall.syslog`.

Les nœuds ne lisent leur collecteur qu'à leur création : activer `observability` sur un déploiement existant demande de les reconstruire un à un. Dans Grafana (`grafana_url` de la sortie `observability`), menu Explore, choisissez la source de logs du projet et filtrez sur `{job="fortigate"}`, puis sur le label `type`. Le journal de trafic (`type="traffic"`) est de loin le plus gros volume : `keep_traffic_log = false` dans `module "observability"` le fait jeter par le relais.

## Détruire

Supprimez d'abord les ressources créées hors Terraform dans le projet (instances, LB, volumes, bases, buckets). Puis :

```bash
terraform destroy
```

Si l'erreur `resource is still in use` apparaît, supprimez les security groups « Default » que Scaleway a créés dans le projet (`terraform output -raw project_id`), dans chaque zone où des VM ont tourné, puis relancez :

```bash
scw instance security-group list zone=fr-par-1 project-id=<id-projet>
scw instance security-group delete <id> zone=fr-par-1
```

La même erreur vient aussi du nettoyage du conteneur de bascule, qui se termine après sa suppression : relancez `terraform destroy` une minute plus tard.

## Dépannage

| Symptôme | Cause | Action |
|---|---|---|
| `insufficient permissions: read security_groups` au premier apply | projet créé quelques secondes plus tôt, droits pas encore propagés | relancer `terraform plan` puis `terraform apply` |
| `need exactly one primary` au push de politique | la paire n'a pas formé de cluster (réseau HA, mot de passe HA) | `get system ha status` sur chaque nœud, puis reconstruire le nœud fautif |
| `out-of-sync` dans `get system ha status` juste après un apply | le secondaire n'a pas encore reçu la politique poussée | attendre une minute ; si cela dure, `diagnose sys ha checksum cluster` montre ce qui diffère |
| `FortiGate time is out of sync` dans le WebUI du secondaire | normal en FGCP : le secondaire n'interroge pas NTP, il prend l'heure du primaire | aucune ; `execute time` donne la même heure sur les deux nœuds |
| `stdio forwarding failed` en SSH vers un firewall | il démarre encore | attendre quelques minutes |
| `REMOTE HOST IDENTIFICATION HAS CHANGED` vers un firewall ou un bastion | nœud reconstruit, ou nouvelle Public Gateway sur l'IP d'une ancienne | `ssh-keygen -R '[<ip-pgw>]:<port>'` pour le bastion, `ssh-keygen -R <ip-mgmt>` pour le nœud |
| `Connection timed out during banner exchange` vers une VM | port fermé par la NACL du spoke | ajouter une règle `nacl_inbound`, puis appliquer |
| plus de trafic via le hub, IPAM de la VIP Hub sur le secondaire | le routeur VPC suit la dernière écriture : déplacement manuel vers le mauvais nœud, ou appel tardif juste après un redémarrage du conteneur | lancer la ligne du primaire de `failover_commands` ; sinon, le rattrapage de la minute 7 corrige |
| `fortigate.sh ready` ou le push de politique échoue en SSH | poste hors de `admin_cidrs`, ou `ssh` ou `scw` manquant | corriger, puis relancer l'apply |
| `admin key never accepted: user data not applied` | le disque avait déjà démarré, ou l'Instance a une IP publique (pas de CD-ROM NoCloud) | repartir du snapshot d'usine, sans IP publique ; en console série, `diagnose debug cloudinit show` |
| le plan refuse `policy.yaml` | syntaxe, alias inconnu, description en double ou contenant `<`, `>` ou `&` | corriger `policy.yaml` |
| le plan refuse les CIDR | chevauchement entre `cidrs`, `spoke_supernet` et l'on-prem | corriger les valeurs |
| le certificat Edge Services n'est pas émis | le CNAME du FQDN manque | créer le CNAME vers `edge_cname_target` |
| `Command cancelled by user` sur `execute ha failover set 1` | commande passée sans terminal (`ssh ... 'cmd'`) | ouvrir une session SSH interactive et répondre `y` |

## Limites connues

- L'IAM Scaleway s'applique à un projet entier : tout opérateur du projet a les mêmes droits sur chaque spoke, le hub et les firewalls. Pour séparer des équipes, prenez la branche `hub-spoke-multi-project`.
- Les chemins Internet créés dans le projet (IP publique d'instance, Load Balancer, nœuds Kapsule avec IP publique) ne passent pas par le firewall. Le contrôle passe par un inventaire : `scw instance ip list project-id=<projet>`, `scw lb list project-id=<projet>`.
- Le state contient le mot de passe `admin`, le mot de passe HA, les user data des firewalls (licences comprises) et les clés de bascule : protégez le bucket.
- Les règles sont en *sloppy state* par défaut : les sessions survivent à une bascule, jamais à la perte d'une Public Gateway, car l'IP publique change. Après une bascule, une session Internet qui attend des données peut rester muette jusqu'à son prochain paquet sortant : voir [HA-CONTENEUR.md](HA-CONTENEUR.md#silence-des-sessions-internet).
- `policy.nat_outbound` n'est pas pris en charge : le trafic Internet des spokes sort par la VIP egress.
- Les NACL laissent revenir TCP et UDP sur 32768-65535 depuis toute source : un service qui écoute sur ces ports est joignable hors du spoke, sauf derrière le security group de référence du spoke (sortie `security_group_ids`). Tout opérateur du projet peut modifier ces groupes : surveillez-les par Audit Trail. Un security group sur une carte Private Network y désactive l'IPv6, et les NACL n'ont ni règles ni routes IPv6.
- Redis, MongoDB, Kafka, OpenSearch et ClickHouse ne suivent pas le routage VPC : ils ne sont joignables que depuis leur Private Network.
- Le trafic d'Edge Services vers les Load Balancers est en HTTP.
- Scaleway n'expose aucun timer BGP, BFD ou DPD : la vitesse de bascule entre les deux tunnels VPN se règle sur la passerelle on-prem.
- Activer `vpn` sur un cluster déjà déployé ne pose pas la route on-prem sur les firewalls : la plateforme n'est lue qu'au premier démarrage. Ajoutez-la sur chaque nœud (`router.static` ne se synchronise pas), `config router static` vers `169.254.169.254` par `port3`, ou reconstruisez les nœuds. Sans elle, un nœud primaire ne renvoie pas le trafic vers l'on-prem.
- Les VM déjà démarrées reçoivent les routes d'un nouveau spoke par DHCP en une heure au plus.
- Une organisation a 512 connecteurs de peering : 127 spokes sans bypass, 85 avec.
