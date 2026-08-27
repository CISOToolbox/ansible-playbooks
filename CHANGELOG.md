# Changelog

## Versioning

This repository is versioned independently of the suite. A playbook version
says nothing about which suite you run — that is `ciso_suite_version`, set in
your own inventory, and the two move on their own schedules.

- **major** — a variable is renamed or removed, a default changes in a way
  that alters an existing deployment, or a playbook stops doing something it
  used to do. Read the notes before upgrading.
- **minor** — new capability, existing deployments unaffected.
- **patch** — fixes and documentation.

Pin a tag rather than tracking `main`. `main` is where a fix lands ten minutes
after it is found, sometimes before it has been run anywhere but here.

## 1.0.0

First tagged release. The template has deployed a production suite, moved it
between directories, upgraded it, and rebuilt it from scratch on a second
machine restoring from an off-site repository alone.

### What it does

- **`site.yml`** — installs and converges a host from a published suite
  release. `docker-compose.yml` and `nginx.conf` are never hand-written: they
  come from the public repository at `ciso_suite_version`.
- **`upgrade.yml`** — the same, plus a dump of every database beforehand, and
  a refusal to continue if one is empty or missing. Alembic migrations do not
  replay backwards.
- **`restore.yml`** — rebuilds a stack on a fresh host and restores a
  designated backup, local or off-site.
- **`verify.yml`** — checks only, writes nothing.

Certificates come in three postures (`provided`, `existing`, `selfsigned`) and
can be replayed alone with `--tags certs`. Off-site S3 backup is configured
through `ciso_backup_s3`, requires a suite release that ships the overlay, and
is refused explicitly on one that does not.

### The guards, and what each of them cost to learn

Every check in this template exists because its absence caused an incident.

- **The project name against existing volumes.** Getting
  `COMPOSE_PROJECT_NAME` wrong produces no error: the stack starts on fresh
  volumes, the databases are empty, and it looks like data loss while the real
  data sleeps under another prefix.
- **Containers from another directory.** Their names are fixed, so `up -d`
  fails on a conflict with an obscure message. The playbook reads the label
  Compose puts on each container and says which directory to stop — and
  distinguishes stopped-but-present containers, since `docker compose stop`
  does not free the names.
- **Boot-time start mechanisms pointing elsewhere.** `down` removes the
  containers and their restart policies, but not a systemd unit or a cron
  `@reboot`. Those surface at the next reboot, weeks later.
- **The image actually in service.** Neither the compose file nor the absence
  of errors proves a container runs on the right image.
- **A usable dump before any migration**, and the first full backup — a
  created stanza proves nothing.

### Behaviours worth knowing before you upgrade to this from nothing

- The host firewall is **not managed** by default. On a Docker host, ufw does
  not arbitrate published ports, and a `deny incoming` policy that lets the
  application ports through is more dangerous than no firewall.
- Docker comes from the **distribution** packages by default. A working Docker
  installation is never replaced, whatever the source.
- The deployment account is created by the `common` role; `restore.yml` loads
  it too, since a recovery host has neither the account nor Docker.
- Certificates are placed as `root:root 0640`: the release's proxy runs
  without `DAC_OVERRIDE` and cannot read a key owned by another account.

See [README.md](README.md) for the procedures and the suite's
[RECOVERY.md](https://github.com/CISOToolbox/suite/blob/main/RECOVERY.md) for
what a restore gives back and what it does not.
