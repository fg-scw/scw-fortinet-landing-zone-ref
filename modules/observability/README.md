# Relais de journaux (optionnel)

Les firewalls envoient leur syslog (RFC 5424, port 514 en UDP et TCP) à une petite VM du réseau Egress de la DSI. Grafana Alloy le pousse dans Scaleway Cockpit (Loki, projet DSI). Pas de HA : si le relais tombe, les firewalls gardent leurs journaux en local. Pas de TLS : le trafic reste dans un Private Network.

Le jeton Cockpit (écriture seule) est lu une fois par le relais, rangé dans `/etc/alloy/cockpit.env` (root et alloy seulement) puis effacé des métadonnées.

## Quand ne pas l'utiliser

Si le client a déjà un SIEM, ne déployez pas cette unité : mettez l'IP de son collecteur dans `firewall.syslog` de la DSI. Supprimez le dossier `live/dsi/observability/` si un déploiement global depuis `live/` ne doit pas l'inclure.

## Activer

1. La DSI doit être déployée ([Déploiement](../../README.md#déploiement)).
2. Déployer l'unité, avec la CLI `scw` disponible sur le poste ou le runner :

   ```bash
   terragrunt apply --working-dir live/dsi/observability
   ```

   Réseau, bastion et clés SSH viennent de la sortie `observability_target` de la DSI. Options : [CONFIGURATION.md](../../docs/CONFIGURATION.md#relais-dobservabilité).
3. Brancher les firewalls : recopier la sortie `syslog_target` dans `firewall.syslog` de la DSI et appliquer. C'est un réglage de plateforme : reconstruisez les nœuds un à un ([Exploitation](../../docs/OPERATIONS.md)).

## Consulter

`terragrunt output grafana_url --working-dir live/dsi/observability` ouvre Grafana. Dans Explore, choisissez la source de logs du projet DSI et filtrez sur `{job="opnsense"}`. Labels disponibles : `host` (hostname syslog du firewall), `program`, `level`.

Accès admin : sortie `access` (SSH par le bastion des Public Gateways).
