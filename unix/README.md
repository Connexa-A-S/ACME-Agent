# CNXA ACME Fetch Agent for Unix

A small, dependency-light counterpart to the Windows agent. It synchronizes a certificate
from the CNXA ACME Platform to a local folder and runs hook scripts when it changes.

## What it does

1. Calls `GET /agent/info` with the service API key.
2. Compares the remote fingerprint with the local state file.
3. Downloads the certificate only when it changed (or when `current/` is missing).
4. Stores it in an immutable `versions/` folder and updates `current/`.
5. Runs hooks in `hooks.d/` in filename order.

## Requirements

- `bash`, `curl`, `sed`, `grep`. PEM output also needs `unzip`.
- `systemd` for the timer (a cron line is printed as a fallback).

## Install

```bash
sudo ./install-agent.sh \
  --api-base-url "https://acme.cnxa.cloud/api" \
  --service-api-key "cnxa_svc_REPLACE_ME" \
  --output-format pem
```

This installs:

```text
/usr/local/sbin/cnxa-acme-fetch      the agent
/etc/cnxa-acme/config.conf           config (chmod 600 — holds the API key)
/etc/cnxa-acme/hooks.d/              hooks (*.sh in filename order)
/var/lib/cnxa-acme/certs/            certificates (versions/ + current/)
/var/log/cnxa-acme/                  logs
```

and enables a systemd timer that runs every 12 h. Run once now:

```bash
sudo systemctl start cnxa-acme-agent.service
# or directly:
sudo CNXA_FORCE=1 /usr/local/sbin/cnxa-acme-fetch /etc/cnxa-acme/config.conf
```

## Output layout

```text
/var/lib/cnxa-acme/certs/<service-name>/
  current/                 cert.crt, cert.key, issuer.crt   (or certificate.pfx)
  versions/<label>/        immutable copy + metadata.txt
```

## Hooks

Hooks are files in `hooks.d/`. A file is run if it is executable, or if its name ends in
`.sh`. They receive the deployment context as environment variables:

```text
CNXA_CURRENT_PATH   CNXA_VERSION_PATH   CNXA_FORMAT
CNXA_SERVICE_ID     CNXA_SERVICE_NAME   CNXA_CUSTOMER_NUMBER
CNXA_DOMAIN         CNXA_FINGERPRINT    CNXA_PREVIOUS_FINGERPRINT
```

Exit codes: `0` OK, `1` warning (continue), `2` retry on next run, `3+` fatal (stops the
pipeline). Each hook gets its own log under `/var/log/cnxa-acme/`.

### Included hooks

`10-example.sh` (active) just prints the context. The rest ship as `*.sh.example` — each
installs the PEM and reloads the service after a config test. **Rename to drop `.example`
to activate**, and set the destination paths (defaults or the `CNXA_*` env vars in each file):

| File | Target |
|------|--------|
| `20-nginx-reload.sh.example` | nginx (`nginx -t` + reload) |
| `30-apache-reload.sh.example` | Apache / httpd (`apachectl -t` + graceful) |
| `40-haproxy-reload.sh.example` | HAProxy (combined PEM, `haproxy -c` + reload) |
| `50-postfix-dovecot-reload.sh.example` | Postfix and/or Dovecot |
| `90-copy-and-run.sh.example` | Generic: copy to a path + restart service / run a command |

All require `OUTPUT_FORMAT=pem`. They are templates — test on a representative host first.

## Config

`config.conf` is plain `KEY=VALUE` (parsed, not sourced). See `config.example.conf`.
Keep `OUTPUT_FORMAT=pem` unless a consumer needs a PFX.
