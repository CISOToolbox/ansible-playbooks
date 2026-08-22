# Déploiement CISO Toolbox par Ansible — Ubuntu 24.04 LTS

Déploie et exploite une stack CISO Toolbox sur un hôte Ubuntu 24.04, à partir
d'une **release publiée** de la suite. Cible `docker compose`, comme la suite
publique.

## Le principe, en une phrase

`docker-compose.yml` et `nginx.conf` ne sont **jamais écrits à la main** : ils
viennent du dépôt public au tag `ciso_suite_version`. Un tag de suite décrit
une combinaison de modules testée ensemble — c'est le manifeste de
compatibilité. Monter de version, c'est changer cette variable et rejouer.

Corollaire : ne mettez pas `main` dans `ciso_suite_version`. Vous déploieriez
une composition que personne n'a validée.

## Mise en route

```bash
cp inventory/hosts.yml.example inventory/hosts.yml
cp group_vars/all/vault.yml.example group_vars/all/vault.yml

# Générer les secrets (openssl rand -hex 32 pour chacun), puis chiffrer
ansible-vault encrypt group_vars/all/vault.yml
echo "monmotdepasse" > .vault_pass && chmod 600 .vault_pass

ansible-galaxy collection install -r requirements.yml
ansible-playbook site.yml --syntax-check     # toujours avant la première fois
ansible-playbook site.yml
```

Les certificats TLS attendus sur le control node :
`files/certs/<domaine>/fullchain.pem` et `privkey.pem`.

## Les trois playbooks

| Playbook | Rôle |
|---|---|
| `site.yml` | Installation et convergence. Idempotent, rejouable. |
| `upgrade.yml` | Montée vers une autre release, avec dump préalable et contrôle des migrations. |
| `verify.yml` | Contrôles seuls, n'écrit rien. |

## Deux secrets à traiter à part

`vault_encryption_key` chiffre les secrets stockés en base — configuration
SMTP, clés IA, jetons de connecteurs. **Le changer rend illisible tout ce qui
a été chiffré avec l'ancien.** Il ne se remplace pas, il se rotationne avec
l'outil dédié.

`vault_backup_cipher` chiffre le dépôt pgBackRest. **Le perdre rend les
sauvegardes irrécupérables** — c'est tout l'intérêt du chiffrement, et tout
le risque. Conservez-le ailleurs que sur la machine sauvegardée.

## Ce que le playbook contrôle, et pourquoi

Ces vérifications viennent d'une migration réelle où chacune a manqué.

**La colonne `Image` de `compose ps`.** Ni le contenu du compose ni l'absence
d'erreur dans les logs ne prouvent qu'un conteneur tourne sur la bonne image.
Un conteneur non recréé garde silencieusement l'ancienne.

**Le proxy est recréé, jamais rechargé.** `nginx.conf` est monté comme fichier
unique, donc attaché à son inode ; la plupart des éditeurs le remplacent, et
`nginx -s reload` relit alors l'ancien contenu — ou échoue.

**Un dump exploitable avant toute migration.** `upgrade.yml` refuse de
continuer si un dump est vide ou manquant : une migration Alembic ne se rejoue
pas à l'envers.

**Le premier backup complet.** Une stanza pgBackRest créée ne prouve rien.
Tant que le premier `full` n'est pas passé, l'archivage WAL tourne sans rien
sur quoi rejouer, et il n'y a aucune fenêtre de restauration.

## Images client

Une image client (add-ons propres à une organisation) remplace l'image de
suite du module :

```yaml
ciso_client_images:
  surface: "ghcr.io/cisotoolbox/ciso-surface-bdfg:v1.0.0"
ciso_registry_user: "mon-compte"        # + vault_registry_password
```

Le tag **et le digest** de la release sont retirés à la substitution : une
image client a ses propres empreintes, garder le digest d'origine ferait
échouer le `pull`.

## Retirer un module

`ciso_modules` pilote `PILOT_MODULES` — donc ce que Pilot propose — et les
contrôles de santé. Il ne retire **pas** les services du `docker-compose.yml`,
qui vient de la release telle quelle. Pour ne pas déployer un module, il faut
retirer ses services du compose après copie, ce que ce template ne fait pas
aujourd'hui : c'est une divergence assumée à porter côté client.

## Le moteur Docker

Par défaut, le rôle installe les paquets de la **distribution** —
`docker.io`, `docker-compose-v2`, `docker-buildx`. Sur Ubuntu 24.04 ils sont
à jour (Docker 29.x, compose 2.40.x), signés par Ubuntu et suivis par
`unattended-upgrades`, sans dépôt tiers dans la chaîne d'approvisionnement de
l'hôte.

Le dépôt officiel Docker Inc. reste disponible si une version amont précise
est nécessaire :

```yaml
ciso_docker_source: "docker-ce"
```

Sur un hôte où `docker compose version` répond déjà, **rien n'est installé**,
quelle que soit la source : `docker-ce` et `docker.io` sont en conflit, et
basculer de l'un à l'autre désinstallerait le moteur en place et arrêterait
les conteneurs en service.

## Le pare-feu de l'hôte

**Non géré par défaut** (`ciso_firewall_manage: false`). C'est une politique
d'établissement, et beaucoup d'hôtes sont déjà filtrés en amont — groupe de
sécurité, pare-feu d'hyperviseur, nftables tenus par l'exploitant. Le
template ne s'y substitue pas.

Si vous l'activez, sachez ce qu'ufw filtre réellement sur un hôte Docker :

> ufw n'arbitre **pas** les ports publiés par les conteneurs. Docker écrit ses
> propres règles — un DNAT en `nat/PREROUTING`, puis la chaîne `DOCKER`
> atteinte depuis `FORWARD`. Les règles d'ufw vivent dans `INPUT`. Un
> conteneur publiant `-p 8080:8080` reste joignable depuis le réseau **même
> avec `deny incoming` actif**.

Pour cette stack, cela veut dire que seul le **port 22** est gouverné par
ufw. Les 80/443 du proxy sont publiés par Docker : les autoriser ne change
rien, et les refuser ne les fermerait pas. Une politique « deny incoming »
qui laisse passer précisément les ports applicatifs est plus dangereuse que
pas de pare-feu du tout — elle rassure à tort.

Le vrai levier est de **ne publier que ce qui doit l'être**. Pour fermer
malgré tout un port publié, il faut la chaîne `DOCKER-USER`, que Docker
consulte avant ses propres règles et ne réécrit jamais ; ce rôle ne va pas
jusque-là, faute de connaître vos réseaux de confiance.

## Ce qui n'est pas couvert

L'obtention des certificats (ni ACME ni PKI interne — ils sont fournis), la
supervision, et la restauration. La restauration se pilote depuis Pilot, qui
a l'interface pour ça.

## Déplacer un déploiement existant

Les volumes Docker sont nommés d'après `COMPOSE_PROJECT_NAME`, **pas** d'après
le répertoire : déplacer un déploiement ne touche pas aux données, tant que le
nom de projet ne change pas. Les conteneurs, eux, portent des noms fixes, donc
l'ancienne stack doit être arrêtée avant que la nouvelle démarre.

```bash
# 1. arrêter l'ancienne — SANS -v, qui détruirait les volumes
cd /ancien/chemin && sudo docker compose down

# 2. déployer au nouvel emplacement
ansible-playbook site.yml --limit <hôte>

# 3. contrôler que les bases sont retrouvées (et non recréées vides)
sudo docker compose -f /opt/ciso-toolbox/docker-compose.yml exec -T pilot-db \
     psql -U pilot -tAc "select count(*) from users"
```

Le rôle refuse de démarrer si une stack tourne encore depuis un autre
répertoire, et nomme celui-ci dans le message — sans ce garde-fou, l'échec se
manifeste par un conflit de noms de conteneurs peu explicite.

Une fois la bascule vérifiée, l'ancien répertoire ne contient plus que des
fichiers de configuration régénérables. Le supprimer est sans effet sur les
données.

## Décrire un hôte

Un déploiement se décrit dans `host_vars/<nom-de-l-hote>.yml`, où le nom doit
correspondre **exactement** à celui de l'inventaire :

```bash
cp host_vars/example-host.yml.example host_vars/mon-serveur.yml
```

Ces fichiers vous appartiennent : le template ne livre qu'un exemple suffixé
`.example`, qu'Ansible ne charge pas. Aucune mise à jour du template ne
touchera donc votre configuration — et vous pouvez la versionner dans ce
dépôt sans craindre un conflit à chaque `git pull`.

Le dépôt ne contient aucun nom de client, domaine ni chemin réel : ils vivent
dans vos fichiers d'hôte et dans votre inventaire, tous deux hors du template.
