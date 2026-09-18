# Agentic Inbox — Proxmox LXC Installer + Setup-WebUI

Lokale Agentic-Inbox-Installation als **LXC-Container auf Proxmox VE** im Stil der
[Proxmox VE Community Scripts](https://community-scripts.github.io/ProxmoxVE/):
**Einzeiler auf dem Host → Container + App + Setup-Portal + systemd läuft.**

> Upstream: [cloudflare/agentic-inbox](https://github.com/cloudflare/agentic-inbox)
> (Self-hosted E-Mail-Client mit KI-Agent, React 19 + Hono auf Cloudflare Workers).
> Dieses Repo legt einen **Proxmox-Wrapper** darum: LXC-Installer (whiptail-Dialoge),
> lokale Emulation (`npm run dev`) als systemd-Service und ein **Setup-Portal**,
> in dem man alles einstellen kann (DOMAINS, Access-Secrets, Restart, Logs).

| Feld | Wert |
|---|---|
| App-Name | `agentic-inbox` |
| Zweck | E-Mail-Client mit KI-Agent lokal im LXC testen/bedienen (lokale Emulation) |
| Tech-Stack | Node.js 20 / TypeScript, React Router v7, Vite, Hono, Wrangler; Portal: Node-stdlib only |
| Upstream-Repo | https://github.com/cloudflare/agentic-inbox |
| Web-UI-Port | `8080` (App), `8081` (Setup-Portal, konfigurierbar) |
| Default-Ressourcen | 2 vCPU · 2048 MB RAM · 8 GB Disk · Debian 12 LXC, `onboot: 1` |

> **Wichtig — was lokal läuft und was nicht:** Agentic Inbox ist nativ für
> Cloudflare Workers gebaut (Durable Objects/SQLite, R2, Workers AI,
> Email Routing, Access). Dieses Setup fährt die **login-freie lokale Emulation**
> (`wrangler.local.jsonc`: ohne `remote`-Bindings, ohne `ai`-Binding):
> Web-UI + Mailbox-Speicherung (lokale DO/R2-Simulation) laufen sofort im LAN.
> **KI-Agent und echter Mail-Versand/-Empfang** haben keine lokale Simulation
> und brauchen danach ein `npm run deploy` auf einen Cloudflare-Account
> mit Domain (dafür nutzt das Deploy die originale `wrangler.jsonc` mit AI-Binding).
> Das Setup-Portal bereitet genau diese Werte
> (`DOMAINS`, `POLICY_AUD`, `TEAM_DOMAIN`) vor.

## 1 · Installation (Einzeiler auf dem Proxmox-Host als root)

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/AgenticInboxProxmox/main/install/agentic-inbox.sh)"
```

Das Script fragt interaktiv ab (mit sinnvollen Defaults):
`CT-ID` (160) · Hostname (agenticinbox) · vCPU (2) · RAM (2048) · Disk (8G) ·
Storage (`local-lvm`) · Bridge (`vmbr0`, DHCP) · App-Port (8080) ·
Setup-Port (8081) · `DOMAINS` (example.com) · `POLICY_AUD`/`TEAM_DOMAIN` (optional).

Danach läuft vollautomatisch:
1. Debian-12-Template sicherstellen (`pveam download` falls nötig)
2. `pct create` + `onboot: 1` + Start
3. Wrapper-Dateien per `pct push` in den Container (`portal/`, `systemd/`, Setup-Script)
4. `install/setup-container.sh` im Container: Node.js 20, Locales, Upstream-Clone,
   `npm ci`, `wrangler.jsonc`/`​.dev.vars` schreiben, **login-freie
   `wrangler.local.jsonc`** generieren (kein `remote`, kein `ai`) +
   `vite.config.ts`-Patch (`configPath`), systemd-Units
   `agentic-inbox.service` + `agentic-inbox-setup.service`
   (`enable`, `Restart=always`, `After=network-online.target`)
5. Selbst-Verifikation: `systemctl is-active` (beide Services) + HTTP-Checks auf
   `localhost:8080/` und `localhost:8081/healthz`

**Erwartete Ausgabe (Ende):**

```text
[7/8] Verifikation ...
  - Service agentic-inbox: active
  - Service agentic-inbox-setup: active
  - HTTP-Check App auf localhost:8080 ...
  - App antwortet (HTTP 200).
  - HTTP-Check Setup-Portal auf localhost:8081/healthz ...
{"status":"ok","service":"agentic-inbox-setup"}
  - Setup-Portal antwortet.
[8/8] Fertig.
==================================================================
 ✅ Fertig! Agentic Inbox (lokale Emulation): http://192.168.1.60:8080
    Setup-Portal (alles einstellen)          : http://192.168.1.60:8081
    ...
==================================================================
```

Web UI öffnen → App auf `:8080` nutzen → **alles einstellen** im Setup-Portal
auf `:8081` (DOMAINS ändern, Access-Secrets nachtragen, Restart, Logs).

## 2 · Erneut laufen lassen / Update

Einfach den Einzeiler erneut ausführen — ist die CT-ID belegt, wird
**automatisch die nächste freie CT-ID genommen** (kein Abbruch, keine Rückfrage).
Für ein gezieltes Update des bestehenden Containers:

```bash
CT_UPDATE=1 bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/AgenticInboxProxmox/main/install/agentic-inbox.sh)"
# -> Setup läuft im bestehenden Container (Code + Deps neu, Services restarten)
```

Oder im Container direkt:

```bash
pct exec 160 -- bash /opt/agentic-inbox/setup-container.sh
```

## 3 · Deinstallation

```bash
pct stop 160 && pct destroy 160
```

## 4 · Reboot-Test (Verifikation)

```bash
pct exec 160 -- reboot
sleep 15
pct exec 160 -- systemctl is-active agentic-inbox agentic-inbox-setup
curl -fsS http://<LXC-IP>:8080/ -o /dev/null && echo "App OK"
curl -fsS http://<LXC-IP>:8081/healthz && echo "Portal OK"
```

Container startet via `onboot: 1` automatisch; beide Services haben
`Restart=always` und `After=network-online.target`.

## 5 · Debugging (komplette Fehlerkette)

Niemals nur die letzte Zeile — bei Fehlern immer volle Kette sichern:

```bash
DEBUG=1 bash -x install/agentic-inbox.sh 2>&1 | tee install.log
pct exec 160 -- journalctl -u agentic-inbox --no-pager -n 100
pct exec 160 -- journalctl -u agentic-inbox-setup --no-pager -n 100
```

## Struktur

```text
AgenticInboxProxmox/
├── install/
│   ├── agentic-inbox.sh     # Host-Installer (Einzeiler, whiptail, pct create/push/exec)
│   └── setup-container.sh   # Setup IM Container (Node 20, npm ci, Units, Verifikation)
├── portal/
│   └── server.mjs           # Setup-WebUI :8081 (stdlib only: Config, Restart, Logs)
├── systemd/
│   ├── agentic-inbox.service        # App :8080 (npm run dev --host 0.0.0.0)
│   └── agentic-inbox-setup.service  # Portal :8081
└── README.md
```
