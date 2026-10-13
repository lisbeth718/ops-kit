# ops-kit

Small bash scripts for watching a handful of Docker servers, built for a solo
founder: no agent, no database, no dashboard. Cron runs a script, the script
checks one thing, and a problem becomes one JSON POST to your webhook (or a line
on stdout if you have none).

Linux servers, bash 4+, `curl`, `jq`, `docker`. `uptime-prober.sh` and `dead-mans-switch.sh` require `ALERT_WEBHOOK_URL` (no stdout fallback, by design: a mute watchdog is no watchdog). Most scripts need GNU `date`.

## Scripts

| Script | What it does |
|---|---|
| `notify.sh` | The one notifier. POSTs `{source, severity, title, body, fingerprint}` to `$ALERT_WEBHOOK_URL` (optional bearer `$ALERT_WEBHOOK_TOKEN`), falls back to stdout. |
| `lib.sh` | Shared helpers (config, host list, ssh with retry, coverage check). Sourced, not run. |
| `cron-report.sh` | Wraps any cron command: times it, re-emits its output, alerts on failure, sends a recovery notice, optional slow-run warning and heartbeat ping. |
| `script-drift-check.sh` | Compares sha256 of the installed scripts on every host against a manifest from git. |
| `mem-headroom-watch.sh` | Containers near their `--memory` cap, measured on the cgroup working set (page cache excluded). |
| `disk-headroom-watch.sh` | Filesystems or inodes above a threshold, per host. |
| `crash-loop-watch.sh` | Containers restarting now or whose restart count jumped since the last run. |
| `cert-expiry-watch.sh` | Served TLS cert days left per domain; catches silently failed auto-renewals. |
| `domain-expiry-watch.sh` | Domain registration expiry via RDAP with whois fallback, escalating 30/14/7/3/expired. |
| `uptime-prober.sh` | HTTP probe with 3 tries, down and recovery alerts, optional JSON `/api/health` deep check. |
| `dead-mans-switch.sh` | Run on a separate box: probes your core and critical domains so you hear about it when monitoring itself is dark. |
| `exposed-port-watch.sh` | Datastore and admin ports (postgres, redis, mongo, ...) bound to a public interface. |
| `cve-scan-watch.sh` | Weekly Trivy scan of running images; fixable CRITICAL alerts, HIGH digest. Timeout plus one retry per image. |
| `ssh-auth-watch.sh` | Successful SSH logins from IPs never seen before (seeds from 30 days of history on first run). |
| `rogue-container-watch.sh` | Running containers that are not on your expected list or an infra pattern. |
| `restore-drill.sh` | Monthly: restores one backup into a scratch Postgres and checks tables and rows. |

Every script has a header comment with its env vars and an example cron line.
All support `DRY=1` (print findings, send nothing).

## Install

```sh
git clone <this repo> && cd ops-kit
sudo install -m 755 bin/*.sh /usr/local/bin/
sudo cp config.example.env /etc/ops-kit.env && sudo chmod 600 /etc/ops-kit.env
sudoedit /etc/ops-kit.env          # webhook, HOSTS, DOMAINS
```

Scripts must stay together (they source `lib.sh` and call `notify.sh` from their
own directory). Try one first: `DRY=1 /usr/local/bin/disk-headroom-watch.sh`.

Cron (`/etc/cron.d/ops-kit`):

```cron
*/15 * * * * root /usr/local/bin/cron-report.sh mem-headroom  /usr/local/bin/mem-headroom-watch.sh
*/30 * * * * root /usr/local/bin/cron-report.sh disk-headroom /usr/local/bin/disk-headroom-watch.sh
*/5  * * * * root /usr/local/bin/cron-report.sh crash-loop    /usr/local/bin/crash-loop-watch.sh
*/5  * * * * root /usr/local/bin/cron-report.sh uptime-prober /usr/local/bin/uptime-prober.sh
20 5 * * *   root /usr/local/bin/cron-report.sh cert-expiry   /usr/local/bin/cert-expiry-watch.sh
40 5 * * *   root /usr/local/bin/cron-report.sh domain-expiry /usr/local/bin/domain-expiry-watch.sh
7  * * * *   root /usr/local/bin/cron-report.sh exposed-port  /usr/local/bin/exposed-port-watch.sh
10 6 * * *   root /usr/local/bin/cron-report.sh rogue-container /usr/local/bin/rogue-container-watch.sh
30 6 * * *   root /usr/local/bin/cron-report.sh script-drift  /usr/local/bin/script-drift-check.sh
0 4 * * 1    root /usr/local/bin/cron-report.sh cve-scan      /usr/local/bin/cve-scan-watch.sh
30 4 3 * *   root /usr/local/bin/cron-report.sh restore-drill /usr/local/bin/restore-drill.sh
```

Fleet scripts reach other hosts over ssh as `$SSH_USER` (key auth, `BatchMode`), so
run them from one box that has keys to the rest. `ssh-auth-watch.sh` runs on each
server itself. `dead-mans-switch.sh` goes on a different box than the rest.

## The cron-report wrapper pattern

Put `cron-report.sh <job> <command...>` in front of every cron command. Output
stays exactly as before, the exit code passes through, and a non-zero exit becomes
an error alert with the output tail. The next success sends a recovery notice.
A script can set the one-line summary with `SUMMARY: <text>` on stdout.

Scripts that report problems through `notify.sh` exit 0 on purpose, so a finding
does not also trip a second "cron failed" alert. A non-zero exit means the script
itself is broken.

## The drift-check pattern

Scripts get copied to servers by hand, so copies rot. Keep a manifest next to the
scripts in git (`scripts.manifest.example`): script, sha256, host names, installed path.

```sh
bin/script-drift-check.sh --regen         # after editing a script: refresh shas, commit, install
bin/script-drift-check.sh --verify-repo   # CI: fail if you forgot --regen
script-drift-check.sh                     # cron: fail if a host runs a stale or missing copy
```

### Creating the manifest

The manifest is not shipped (only `scripts.manifest.example`). Create it once:

```sh
cp scripts.manifest.example bin/scripts.manifest   # edit host names and installed paths
bin/script-drift-check.sh --regen                  # fill in the sha256 values
sudo install -D -m 644 bin/scripts.manifest /usr/local/share/ops-kit/scripts.manifest
```

Host names must match the names in `HOSTS`. Without a manifest the check prints a
clear "no manifest" message (and sends an error alert) instead of failing silently.
Drift is reported through the notifier and the script exits 0, so the cron wrapper
does not alert twice.

## Notifier payload

```json
{"source":"disk-headroom","severity":"warn","title":"disk filling on web1","body":"...","fingerprint":"disk-headroom:web1"}
```

`severity` is `info`, `warn`, `error` or `resolved`. `fingerprint` is stable per
problem so the receiver can dedupe and close alerts. To adapt to Slack, Discord,
ntfy or similar, point `ALERT_WEBHOOK_URL` at a small relay, or edit `notify.sh`
(it is the only place that knows about the webhook).

## License

MIT
