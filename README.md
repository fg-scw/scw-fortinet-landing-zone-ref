# Landing zone Scaleway hub & spoke avec FortiGate

Socle réseau d'un projet Scaleway, en Terraform. Le hub porte deux firewalls FortiGate en haute disponibilité FGCP actif-passif (un par zone), la sortie Internet, le VPN et Interlink. Chaque spoke a ses deux VPC (Pub et Private) et ses NACL, dans le même projet que le hub. Ajouter un spoke ne touche pas aux firewalls.

Tout flux qui sort d'un spoke, ou qui y entre depuis l'extérieur, passe par le firewall. Il y a deux exceptions : le contournement Interlink (`hybrid_bypass`) et ce qu'un spoke expose lui-même (Load Balancer, IP publique). Voir les [limites](docs/OPERATIONS.md#limites-connues).

Dans un seul projet, l'IAM ne sépare pas les spokes : tout opérateur du projet agit sur tous les spokes et sur le hub. Cette variante convient à une seule équipe d'exploitation. La branche `hub-spoke-multi-project` donne à chaque spoke son propre projet et son groupe IAM.

<img alt="Vue d'ensemble : tout flux qui sort d'un spoke traverse la paire FortiGate du hub ; hub et spokes partagent un seul projet." src="docs/lz-overview.svg">

Les firewalls démarrent sur l'image d'usine de Fortinet et se configurent seuls au premier démarrage, avec les user data cloud-init de leur Instance. Terraform vérifie ensuite chaque nœud par le bastion et pousse la politique.

<img alt="Premier démarrage : Terraform écrit les user data, FortiOS les lit une seule fois sur le CD-ROM NoCloud, puis fortigate.sh vérifie le nœud par le bastion et pousse la politique." src="docs/lz-provisioning.svg">

## Contenu

```text
main.tf                    hub, spokes, expositions et relais de journaux
variables.tf, outputs.tf   entrées et sorties
terraform.tfvars.example   modèle de configuration
policy.yaml.example        modèle de politique firewall
backend.hcl.example        modèle de backend S3 pour le state
modules/hub                firewalls, VPC du hub, VPN, Interlink, bascule
modules/spoke              VPC Pub et Private, NACL et security groups d'un spoke
modules/endpoint           Load Balancers et Edge Services
modules/observability      relais syslog vers Cockpit (optionnel)
```

## Prérequis

- Terraform 1.10 ou plus récent, la CLI `scw` et `ssh` sur la machine qui déploie. `scw` démarre les firewalls une fois leurs cartes posées et efface leurs user data. `ssh` contrôle les nœuds par le bastion, depuis une adresse de `admin_cidrs`.
- Une clé API d'organisation, d'administrateur par exemple : Terraform crée le projet, ainsi que les applications et clés IAM de la bascule.
- Un bucket Object Storage privé et versionné pour le state. Il contient le mot de passe `admin`, les licences et les clés API de bascule.
- Une licence FortiGate-VM BYOL par nœud (fichier `.lic`, jamais versionné).
- Les zones `fr-par-1` et `fr-par-2` (`fr-par-3` n'a ni Public Gateway ni Load Balancer).

```bash
export SCW_ACCESS_KEY=<clé> SCW_SECRET_KEY=<secret> SCW_DEFAULT_ORGANIZATION_ID=<id-organisation>
export AWS_ACCESS_KEY_ID=$SCW_ACCESS_KEY AWS_SECRET_ACCESS_KEY=$SCW_SECRET_KEY   # accès au bucket du state
scw object bucket create name=<bucket> region=fr-par enable-versioning=true      # privé par défaut
```

## Déploiement

1. Importer le qcow2 FortiOS KVM d'usine (le `fortios.qcow2` du zip Fortinet, déposé dans un bucket de la région), un snapshot par zone :

   ```bash
   aws s3 cp fortios.qcow2 s3://<bucket>/fortios.qcow2 --endpoint-url https://s3.fr-par.scw.cloud
   scw block snapshot import-from-object-storage zone=fr-par-1 bucket=<bucket> key=fortios.qcow2 name=fortios-<version>
   scw block snapshot import-from-object-storage zone=fr-par-2 bucket=<bucket> key=fortios.qcow2 name=fortios-<version>
   ```

   Ne démarrez jamais d'Instance sur ces snapshots à la main : un disque qui a déjà démarré ignore ses user data.

2. Copier `terraform.tfvars.example` en `terraform.tfvars` et `backend.hcl.example` en `backend.hcl`, puis les remplir : identifiants des snapshots (`<zone>/<uuid>`), licences, `admin_cidrs`, spokes. Avec `observability = true`, gardez `firewall.syslog` sur l'adresse du relais dès ce premier apply : un nœud ne lit ce réglage qu'à sa création. Pour ajouter des règles au firewall, copier `policy.yaml.example` en `policy.yaml`. Les options avancées du hub (plan d'adressage, numéros d'hôte, taille des Public Gateways) sont des arguments de `module "hub"` dans `main.tf`, décrits dans `modules/hub/variables.tf`.

3. Déployer :

   ```bash
   terraform init -backend-config=backend.hcl
   terraform plan -out=tfplan
   terraform apply tfplan
   ```

   L'apply attend que les deux nœuds soient prêts (environ 3 min 30), puis pousse la politique.

4. Récupérer les accès (SSH par le bastion, WebUI par tunnel `ssh -L`) et le mot de passe `admin` :

   ```bash
   terraform output -json access
   terraform output -raw fw_admin_password
   ```

   Si une exposition utilise Edge Services, créez un CNAME de chaque FQDN vers son `edge_cname_target` (sortie `endpoints`), sans quoi le certificat n'est pas émis.

## Tests

Ils tournent hors ligne, sans appel à Scaleway :

```bash
terraform init -backend=false && terraform test
for m in hub spoke endpoint observability; do terraform -chdir=modules/$m init -backend=false && terraform -chdir=modules/$m test; done
```

## Documentation

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) : flux, adressage, filtrage, administration, premier démarrage, bascule.
- [docs/OPERATIONS.md](docs/OPERATIONS.md) : spokes, politique, reconstruction d'un firewall, journaux, destruction, dépannage, limites.
