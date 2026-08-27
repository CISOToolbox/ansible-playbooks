# CISO Toolbox deployment with Ansible — Ubuntu 24.04 LTS

Deploys and operates a CISO Toolbox stack on an Ubuntu 24.04 host, from a
**published release** of the suite. Targets `docker compose`, like the public
suite.

## The principle, in one sentence

`docker-compose.yml` and `nginx.conf` are **never hand-written**: they come
from the public repository at tag `ciso_suite_version`. A suite tag describes
a combination of modules tested together — it is the compatibility manifest.
Upgrading means changing that variable and replaying.

Corollary: do not put `main` in `ciso_suite_version`. You would deploy a
combination nobody has validated.

## The four playbooks

| Playbook | When | What it adds |
|---|---|---|
| `site.yml` | installation, and every convergence afterwards | nothing more: idempotent, replay at will |
| `upgrade.yml` | change of `ciso_suite_version` | a dump of every database first, then checks on migrations and startup errors |
| `verify.yml` | any time | checks only, writes nothing |
| `restore.yml` | after losing the host | rebuilds the stack and restores a designated backup |

`upgrade.yml` does everything `site.yml` does. The difference is its guards:
it **refuses to run** if a dump is empty or missing, because an Alembic
migration does not replay backwards.

---

# Deploying from scratch

## 1. The control node

```bash
git clone <this repository> && cd ansible-playbooks
ansible-galaxy collection install -r requirements.yml
```

## 2. The inventory

```bash
cp inventory/hosts.yml.example inventory/hosts.yml
```

The name you give the host in this file is structural: `host_vars/<name>.yml`
must carry **exactly** the same one. A file whose name does not match is
never loaded, silently.

## 3. The secrets

```bash
cp group_vars/all/vault.yml.example group_vars/all/vault.yml
```

Generate each value with `openssl rand -hex 32`, then encrypt:

```bash
ansible-vault encrypt group_vars/all/vault.yml
echo "<vault password>" > .vault_pass && chmod 600 .vault_pass
```

The **directory** form (`group_vars/all/`) is mandatory. A
`group_vars/all.vault.yml` would never be loaded: Ansible matches a file to
the group bearing exactly its name, and "all.vault" is not "all".

## 4. The host

```bash
cp host_vars/example-host.yml.example host_vars/<host-name>.yml
```

These files are yours — the template ships only a `.example`, which Ansible
does not load. No template update will ever touch your configuration, and you
can version it here without a conflict at every `git pull`. Fill in at least:
`ciso_domain`, `ciso_deploy_dir`, `ciso_deploy_user`, `ciso_tls_mode`, and the
`ciso_env` block.

## 5. The certificates

See *Installing and renewing certificates* below. The proxy will not start
without them, whatever the mode.

## 6. Deploy

```bash
ansible-playbook site.yml --syntax-check         # always, before the first run
ansible-playbook site.yml --limit <host> --check --diff
ansible-playbook site.yml --limit <host>
```

`--check` does not cover everything: the release clone does not happen there,
so copying the compose file and the `docker compose config` validation are
skipped — the playbook says so explicitly. The state checks (data volumes,
existing containers) do run for real, and those are the most useful ones
before a first start.

On a host already running **another** project, the volume check will refuse a
genuinely new deployment: it sees `*-pgdata` volumes that do not carry your
prefix and assumes a typo in `COMPOSE_PROJECT_NAME`. Pass
`-e ciso_allow_new_project=true` then. Never delete the volumes it lists —
they belong to the other project.

## 7. Check

```bash
ansible-playbook verify.yml --limit <host>
```

---

# Installing and renewing certificates

Three postures, depending on how the certificate arrives. The mode is chosen
with `ciso_tls_mode`, and an unknown value is rejected explicitly.

## `provided` — supplied from the control node

The mode for a reproducible deployment from scratch.

```bash
mkdir -p files/certs/<domain>
cp fullchain.pem files/certs/<domain>/cert.pem
cp privkey.pem   files/certs/<domain>/key.pem
```

The destination names are those of `ciso_tls_cert_name` / `ciso_tls_key_name`
(`cert.pem` / `key.pem` by default): the source file must carry the same name
as its destination, and the directory must match `ciso_domain` exactly.

`files/certs/` is excluded by the `.gitignore`. To version the key anyway —
useful when several people deploy — encrypt it: the `copy` module decrypts
vaulted sources transparently.

```bash
ansible-vault encrypt files/certs/<domain>/key.pem
```

## `existing` — already on the host

For a certificate placed by certbot or a corporate PKI. The playbook checks
it is there and fixes its permissions, without ever overwriting it — renewal
stays driven by whatever issued it.

## `selfsigned` — mock-ups only

Generates a self-signed certificate on the host, with a SAN covering the
domain and its subdomains. No browser will accept it. The task is idempotent
through `creates`: to regenerate one, delete the existing certificate first.

## Replaying the certificates alone

```bash
ansible-playbook site.yml --tags certs --limit <host>
```

Copy, permissions, and recreation of the proxy if a file changed — without
touching the rest of the stack. This is the command for every renewal.

The playbook places the certificates as `root:root 0640`, inside a `certs/`
directory in `0750`. That is not cosmetic: the release's proxy runs with
`cap_drop: ALL`, therefore **without `DAC_OVERRIDE`**, and its root process is
subject to permission bits like any other user. A `privkey.pem` in `0600` for
another account — what certbot and most PKIs produce — makes nginx loop on
`cannot load certificate key ... Permission denied`, proxy in `Restarting`
and the suite unreachable. Making the container the file's owner is enough,
without exposing it to the host's other accounts.

Only the permissions of the mounted directory and its contents matter: a bind
mount resolves its path on the host side at mount time, and the container's
process only traverses its own tree. The mode of the deployment directory
plays no role here.

---

# Upgrading an existing deployment

## 1. Choose the target

Change `ciso_suite_version` in `group_vars/all/main.yml` — or in the host's
`host_vars`, to upgrade a single environment.

## 2. Upgrade

```bash
ansible-playbook upgrade.yml --limit <host>
```

What the playbook does, in order:

1. shows the currently deployed version and the target;
2. **dumps every database** into `<deployment>/dumps/`, as `0700 root`;
3. **refuses to continue** if a dump is empty or missing — an empty dump
   signals an unreachable database, and without a backup a failed migration
   is irreversible;
4. deploys the new release (everything `site.yml` does);
5. re-reads the logs to trace the **Alembic migrations** applied at startup;
6. counts the `traceback` / `critical` / `refusing to start` lines that
   appeared since the update and alerts if there are any;
7. checks the backups.

## 3. Verify

```bash
ansible-playbook verify.yml --limit <host>
```

## Rolling back

There is **no** automatic rollback, and that is deliberate: Alembic
migrations are irreversible. Putting the old `ciso_suite_version` back would
run old code against an advanced schema.

Rolling back therefore means restoring: redeploy the previous version, then
reload the dumps from step 2. That is the reason for the guard that refuses
to start without them.

Before an upgrade that worries you, check whether migrations are even
involved — if the images are identical, there are none:

```bash
ansible-playbook site.yml --tags stack --check --diff --limit <host>
```

---

# Off-site backups, and restoring

The pgBackRest repository lives in a Docker volume, **on the same host and
the same disk as the databases it protects**. That covers logical failure — a
bad migration, an accidental delete. It does not cover losing the host: dead
disk, destroyed VM, ransomware. In those cases, databases and backups
disappear together.

## Enabling the off-site repository

In `host_vars/<host>.yml`:

```yaml
ciso_backup_s3:
  bucket: "my-ciso-backups"
  endpoint: "s3.fr-par.scw.cloud"
  region: "fr-par"
  retention_full: 4
  uri_style: "host"        # "path" for MinIO and compatibles
```

And in `group_vars/all/vault.yml`, encrypted:

```yaml
ciso_backup_s3_secret:
  key: "..."
  key_secret: "..."
  cipher_pass: "..."       # optional — falls back to BACKUP_CIPHER_PASS
```

Then replay `site.yml`. Dictionary absent or empty ⇒ nothing changes: the
second repository does not exist, it is not configured to an empty value.

**A distinct passphrase for the off-site repository** is recommended. That
repository is exposed to a third party — the storage provider — where the
local one is not. Separate keys let you entrust one without handing over the
other. Losing it makes the off-site backups unrecoverable, exactly like
`vault_backup_cipher` for the local repository.

**Restrict the credentials to that bucket alone** — but they must be complete
ones. pgBackRest needs to list, read, write and delete; a "write-only" key
does not work, and a missing **list** permission surfaces as `AccessDenied` on
a fresh repository rather than as a missing object. Protection against
ransomware comes from object lock, not from removing the read permission.

The full table, the reason behind the misleading 403, and the source-IP
filtering case are in the suite's
[RECOVERY.md](https://github.com/CISOToolbox/suite/blob/main/RECOVERY.md) —
they describe the product, not this template, and are kept in one place so a
correction cannot land on only one side.

## What enabling it changes on the host

WAL archiving switches to **asynchronous**, and that is not a performance
detail: without it, one unreachable repository stops the others from moving
more than one segment ahead, `pg_wal` fills, and the database stops. The
playbook therefore enables it together with the second repository, and
allocates one queue volume per database.

Why that is so, and what an internal object storage must serve, is explained
in [RECOVERY.md](https://github.com/CISOToolbox/suite/blob/main/RECOVERY.md).

## Checking

```bash
ansible-playbook verify.yml --limit <host>
```

It checks the freshness of **both** repositories separately. "Local fresh,
off-site behind" is the failure mode to watch: the local repository makes
itself known immediately, the off-site one fails silently — expired
credentials, a moved bucket, retention imposed by the provider. A `-1` marks
a stanza with no off-site backup at all: the protection against losing the
host does not exist.

The agent also restores **one database per month from the off-site
repository**, rotating across the modules. An off-site repository that has
never been restored is a hypothesis, not a backup.

## Restoring

```bash
# Latest backup, every module
ansible-playbook restore.yml --limit <host> \
  -e restore_repo=2 -e restore_target=latest \
  -e restore_confirm=<host>

# At a precise point in time — JSON FORM MANDATORY, see below
ansible-playbook restore.yml --limit <host> \
  -e restore_repo=2 -e restore_confirm=<host> \
  -e '{"restore_target": "2026-08-22 20:00:00+00"}'

# One module only
ansible-playbook restore.yml --limit <host> \
  -e restore_repo=2 -e restore_modules=risk -e restore_confirm=<host>
```

The playbook **overwrites** the targeted databases, hence `restore_confirm`,
which must equal the host name: a recovery is run under pressure, which is
exactly when one targets the wrong machine.

On a fresh host, `restore.yml` installs the suite first, then restores. It
assumes no access to the old machine — the repository passphrase and the S3
credentials are enough.

> **The timestamped-target trap.** With `-e key=value`, Ansible splits on
> spaces: `-e restore_target="2026-08-22 20:00:00+00"` becomes `2026-08-22`,
> and you restore to **midnight** without the slightest warning, losing the
> twenty hours you meant to keep. Use the JSON form. The playbook now refuses
> a date without a time, to make this trap loud rather than silent.

After restoring to a point in time before a migration, the schema may lag
behind the code: modules apply Alembic when they start, and the playbook
prints the revision obtained for each database.

## Before you need it: what a recovery actually requires

A recovery is not only a restore. Four things must be true *before* the host
is lost, and each of them was found the hard way during a real rehearsal on a
second machine.

**The vault is the only artefact backups cannot reconstruct**, and **the
recovery host must be sized like the original** — both are product-level facts,
explained with their failure modes in
[RECOVERY.md](https://github.com/CISOToolbox/suite/blob/main/RECOVERY.md).
What follows is specific to this template.

**Build the host file with `extract-env.sh`, never by hand.** The script
carries the whole `.env` and splits secrets from the rest. A hand-written
file enumerating "the keys that matter" silently loses the others — in the
rehearsal it kept 10 keys out of 34, dropping all three identity providers,
and the recovered stack came up with no authentication. This is the same
failure mode `env.j2` avoids by rendering dictionaries rather than a fixed
list of names.

**`host_vars` REPLACES `ciso_env`, it does not merge it.** Anything inherited
from the `group_vars` default — `AUTH_MODE`, `APP_URL`, `PUBLIC_BASE_URL` —
disappears the moment a host file defines its own `ciso_env`. Repeat those
keys in the host file, or lose them without a warning.

## Reading the vault password

`ansible.cfg` deliberately does not set `vault_password_file`: forcing it
there makes even `--syntax-check` fail on a freshly cloned repository. Writing
the password to `.vault_pass` is therefore not enough on its own — point
Ansible at it:

```bash
export ANSIBLE_VAULT_PASSWORD_FILE=.vault_pass     # for the whole shell
ansible-playbook … --vault-password-file .vault_pass
ansible-playbook … --ask-vault-pass                # nothing written to disk
```

And if the account needs a password for `sudo`, add `-K`: the playbooks run
with `become: true` and `become_ask_pass = False`, so without it the very
first task fails on `sudo: a password is required`.

## Rehearsing a recovery

A rehearsal leaves the original host alive, so both deployments share one
off-site repository and the restored copy's agent will expire the source's
backups. Stop it as soon as the restore succeeds:

```bash
sudo docker compose stop backup-agent
```

In a real recovery the question does not arise, the old host being gone. The
other differences between a rehearsal and the real thing are in
[RECOVERY.md](https://github.com/CISOToolbox/suite/blob/main/RECOVERY.md).

---

# Moving an existing deployment

Docker volumes are named after `COMPOSE_PROJECT_NAME`, **not** after the
directory: moving a deployment does not touch the data, as long as the project
name stays the same. Containers, on the other hand, carry fixed names, so the
old stack must be stopped before the new one starts.

```bash
# 1. stop the old one — WITHOUT -v, which would destroy the volumes
cd /old/path && sudo docker compose down

# 2. deploy at the new location
ansible-playbook site.yml --limit <host>

# 3. check that the databases were found again (and not recreated empty)
sudo docker compose -f /opt/ciso-toolbox/docker-compose.yml exec -T pilot-db \
     psql -U pilot -tAc "select count(*) from users"
```

The role refuses to start if a stack is still running from another directory,
and names that directory in the message — without this guard, the failure
shows up as an unhelpful container-name conflict.

`docker compose stop` is not enough: it stops the containers without removing
them, and their names stay reserved. Only `down` frees them.

Once the switch is verified, the old directory holds nothing but regenerable
configuration files. Deleting it has no effect on the data.

One trap `down` does not handle: an **automatic start** that relaunches the
old directory. `down` removes the containers, hence their `restart` policies —
but not a systemd unit, a cron `@reboot` or an `rc.local`. Those survive and
only show up at the next reboot, when two stacks fight over the same container
names and the same ports, weeks after the move.

The release relies on `restart: unless-stopped`: the stack comes back at boot
on its own, with no unit and no cron entry. Any external mechanism found is
therefore to be disabled, and the playbook reports it. **User** units escape
its search — check them by hand:

```bash
systemctl --user list-unit-files --state=enabled
loginctl show-user <account> -p Linger    # Linger=yes ⇒ they start without a session
```

---

## Two secrets to handle separately

`vault_encryption_key` encrypts the secrets stored in the database — SMTP
configuration, AI keys, connector tokens. **Changing it makes everything
encrypted with the old one unreadable.** It is not replaced, it is rotated
with the dedicated tool.

`vault_backup_cipher` encrypts the pgBackRest repository. **Losing it makes
the backups unrecoverable** — that is the whole point of encryption, and the
whole risk. Keep it somewhere other than the machine being backed up.

## What the playbook checks, and why

These checks come from a real migration where each of them was missing.

**The `Image` column of `compose ps`.** Neither the contents of the compose
file nor the absence of errors in the logs prove that a container runs on the
right image. A container that was not recreated silently keeps the old one.

**The proxy is recreated, never reloaded.** `nginx.conf` is mounted as a
single file, therefore bound to its inode; most editors replace it, and
`nginx -s reload` then re-reads the old content — or fails.

**A usable dump before any migration.** `upgrade.yml` refuses to continue if
a dump is empty or missing: an Alembic migration does not replay backwards.

**The first full backup.** A created pgBackRest stanza proves nothing. Until
the first `full` has run, WAL archiving turns without anything to replay onto,
and there is no recovery window at all.

**The project name against the existing volumes.** Getting
`COMPOSE_PROJECT_NAME` wrong produces no error: the stack starts on fresh
volumes, the databases are empty, and it looks like data loss while the real
data sleeps intact under another prefix.

## Client images

A client image (add-ons specific to one organisation) replaces the module's
suite image:

```yaml
ciso_client_images:
  surface: "ghcr.io/cisotoolbox/ciso-surface-acme:v1.0.0"
ciso_registry_user: "my-account"        # + vault_registry_password
```

The release tag **and digest** are stripped during substitution: a client
image has its own fingerprints, and keeping the original digest would make
the `pull` fail.

## Removing a module

`ciso_modules` drives `PILOT_MODULES` — hence what Pilot offers — and the
health checks. It does **not** remove the services from `docker-compose.yml`,
which comes from the release as it is. To avoid deploying a module you must
remove its services from the compose file after copying, which this template
does not do today: that is an accepted divergence to carry on the client side.

## The Docker engine

By default the role installs the **distribution** packages — `docker.io`,
`docker-compose-v2`, `docker-buildx`. On Ubuntu 24.04 they are current
(Docker 29.x, compose 2.40.x), signed by Ubuntu and covered by
`unattended-upgrades`, with no third-party repository in the host's supply
chain.

Docker Inc.'s official repository stays available when a precise upstream
version is required:

```yaml
ciso_docker_source: "docker-ce"
```

On a host where `docker compose version` already answers, **nothing is
installed**, whatever the source: `docker-ce` and `docker.io` conflict, and
switching from one to the other would uninstall the engine in place and stop
the containers in service.

## The host firewall

**Not managed by default** (`ciso_firewall_manage: false`). It is an
organisational policy, and many hosts are already filtered upstream — cloud
security group, hypervisor firewall, nftables owned by the operator. The
template does not substitute itself for those.

If you enable it, know what ufw actually filters on a Docker host:

> ufw does **not** arbitrate ports published by containers. Docker writes its
> own rules — a DNAT in `nat/PREROUTING`, then the `DOCKER` chain reached from
> `FORWARD`. ufw's rules live in `INPUT`. A container publishing
> `-p 8080:8080` stays reachable from the network **even with `deny incoming`
> active**.

For this stack, that means only **port 22** is governed by ufw. The proxy's
80/443 are published by Docker: allowing them changes nothing, and denying
them would not close them. A "deny incoming" policy that lets exactly the
application ports through is more dangerous than no firewall at all — it
reassures wrongly.

The real lever is to **publish only what must be published**. To close a
published port anyway you need the `DOCKER-USER` chain, which Docker consults
before its own rules and never rewrites; this role does not go that far, not
knowing your trusted networks.

## What is not covered

Obtaining the certificates (neither ACME nor an internal PKI — they are
supplied) and monitoring.

---

The repository contains no client name, domain or real path: those live in
your host files and your inventory, both outside the template.
