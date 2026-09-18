#!/usr/bin/env bash
# =============================================================================
# Agentic Inbox — Container-Setup (läuft IM LXC, Debian 12, als root)
# Wird vom Host-Installer per pct push + pct exec aufgerufen oder manuell:
#   curl -fsSL https://raw.githubusercontent.com/HatchetMan111/AgenticInboxProxmox/main/install/setup-container.sh | bash
# Idempotent: mehrfach lauffähig (Upstream-Pull, npm ci, Build, Units neu).
# Architektur: Production-BUILD wird lokal via `wrangler dev` serviert
# (Dev-Modus `npm run dev` geht NICHT: 6-MB-SSR-Chunk sprengt den Vite-Runner-
# Transport -> "Network connection lost" + HTTP 500).
# Debugging: DEBUG=1 bash -x setup-container.sh  -> volles Trace-Log
# =============================================================================
set -euo pipefail

# --- Variablen (oben, Community-Scripts-Stil) ---------------------------------
APP="agentic-inbox"
BASE_DIR="/opt/agentic-inbox"
APP_DIR="${BASE_DIR}/app"
BUILD_DIR="${APP_DIR}/build/server"
PORTAL_DIR="${BASE_DIR}/portal"
REPO_FILES_DIR="${BASE_DIR}/repo-files"
STATE_DIR="${BASE_DIR}/.wrangler-state"
UPSTREAM_REPO="https://github.com/cloudflare/agentic-inbox.git"
WEB_PORT="${WEB_PORT:-8080}"
SETUP_PORT="${SETUP_PORT:-8081}"
DOMAINS="${DOMAINS:-example.com}"
POLICY_AUD="${POLICY_AUD:-}"
TEAM_DOMAIN="${TEAM_DOMAIN:-}"
APP_SERVICE="agentic-inbox"
SETUP_SERVICE="agentic-inbox-setup"

# --- Fehlerkette: immer VOLL ausgeben, nie nur letzte Zeile -------------------
fail() {
  local code=$?
  echo "==================================================================" >&2
  echo "[FATAL] Setup fehlgeschlagen (Exit-Code: ${code})" >&2
  echo "--- Befehl / Kontext ---" >&2
  echo "Befehl : ${BASH_COMMAND}" >&2
  echo "Zeile  : ${BASH_LINENO[0]:-?} in ${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}" >&2
  echo "--- Stacktrace ---" >&2
  local i
  for ((i=0; i<${#FUNCNAME[@]}; i++)); do
    echo "  #${i} ${FUNCNAME[$i]:-main} @ ${BASH_SOURCE[$i]}:${BASH_LINENO[$i]:-?}" >&2
  done
  echo "--- Relevante Logs ---" >&2
  journalctl -u "${APP_SERVICE}" --no-pager -n 50 2>&1 | tail -n 50 >&2 || true
  journalctl -u "${SETUP_SERVICE}" --no-pager -n 50 2>&1 | tail -n 50 >&2 || true
  echo "Tipp: Re-Run mit Debug-Trace: DEBUG=1 bash -x $0" >&2
  echo "==================================================================" >&2
  exit "${code}"
}
trap fail ERR

if [[ "${DEBUG:-0}" == "1" ]]; then set -x; fi

echo "[1/9] Systempakete + Node.js 20 ..."
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
  git curl ca-certificates build-essential jq locales
# Locales erzeugen (Debian-LXC-Templates haben keine -> sonst perl/apt-Warnflut)
if ! locale -a 2>/dev/null | grep -qi "en_US.utf8"; then
  sed -i -E 's/^# (en_US\.UTF-8 UTF-8)/\1/' /etc/locale.gen
  locale-gen en_US.UTF-8
  update-locale LANG=en_US.UTF-8
fi
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
# Node 20 (Debian-12-Standard ist 18.x — zu alt für Vite 6 / React Router 7)
if ! command -v node >/dev/null || ! node --version | grep -qE "^v(20|22)\."; then
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
  apt-get install -y --no-install-recommends nodejs
fi
node --version
npm --version

echo "[2/9] Upstream klonen/aktualisieren (${UPSTREAM_REPO}) ..."
mkdir -p "${BASE_DIR}" "${STATE_DIR}"
if [[ -d "${APP_DIR}/.git" ]]; then
  git -C "${APP_DIR}" fetch --all --prune
  git -C "${APP_DIR}" pull --ff-only || git -C "${APP_DIR}" reset --hard origin/main
else
  rm -rf "${APP_DIR}"
  git clone --depth 1 "${UPSTREAM_REPO}" "${APP_DIR}"
fi

echo "[3/9] Dependencies installieren (npm ci, idempotent) ..."
cd "${APP_DIR}"
if [[ -f package-lock.json ]]; then
  npm ci --no-audit --no-fund
else
  npm install --no-audit --no-fund
fi

echo "[4/9] Konfiguration schreiben (DOMAINS, .dev.vars, Lokal-Config, Patches) ..."
# wrangler.jsonc: DOMAINS ersetzen (JSONC bleibt erhalten, nur der Wert).
# Bleibt bewusst deploy-fähig (mit AI-Binding) — lokal nutzen wir wrangler.local.jsonc.
if grep -q '"DOMAINS"' wrangler.jsonc; then
  # Domain-String escapen (nur " und \ relevant)
  DOM_ESC="${DOMAINS//\\/\\\\}"
  DOM_ESC="${DOM_ESC//\"/\\\"}"
  sed -i -E "s/\"DOMAINS\"[[:space:]]*:[[:space:]]*\"[^\"]*\"/\"DOMAINS\": \"${DOM_ESC}\"/" wrangler.jsonc
else
  echo "WARN: kein DOMAINS-Key in wrangler.jsonc gefunden" >&2
fi
grep -o '"DOMAINS"[[:space:]]*:[[:space:]]*"[^"]*"' wrangler.jsonc || true
# .dev.vars: Access-Secrets nur schreiben wenn gesetzt (für späteren Cloudflare-Deploy)
touch .dev.vars
chmod 600 .dev.vars
upsert_dev_var() { # key value (leer -> nichts tun)
  local key="$1" val="$2"
  [[ -n "${val}" ]] || return 0
  if grep -qE "^${key}=" .dev.vars; then
    sed -i -E "s|^${key}=.*|${key}=${val}|" .dev.vars
  else
    printf '%s=%s\n' "${key}" "${val}" >> .dev.vars
  fi
}
upsert_dev_var "POLICY_AUD" "${POLICY_AUD}"
upsert_dev_var "TEAM_DOMAIN" "${TEAM_DOMAIN}"

echo "[4b/9] Login-freie Lokal-Config (wrangler.local.jsonc) ..."
# Hintergrund: Upstream-wrangler.jsonc enthält "send_email" mit "remote": true
# (-> Miniflare startet Remote-Proxy-Session -> Cloudflare-Login Pflicht) und ein
# "ai"-Binding (Workers AI hat KEINE lokale Simulation -> braucht ebenfalls Login).
# Zusätzlich SKIP_ACCESS=1 (Bypass für die Access-Middleware im lokalen Build).
node -e '
const fs = require("fs");
let raw = fs.readFileSync("wrangler.jsonc", "utf8");
raw = raw.replace(/,\s*"remote"\s*:\s*true/g, "");
raw = raw.replace(/"remote"\s*:\s*true\s*,?/g, "");
const before = raw;
raw = raw.replace(/"ai"\s*:\s*\{[^{}]*\},?/g, "");
if (raw === before) console.log("HINWEIS: kein ai-Block in wrangler.jsonc gefunden");
if (!/"SKIP_ACCESS"/.test(raw)) {
  raw = raw.replace(/"vars"\s*:\s*\{/, "\"vars\": {\n\t\t\"SKIP_ACCESS\": \"1\",");
}
fs.writeFileSync("wrangler.local.jsonc", raw);
console.log("wrangler.local.jsonc geschrieben");
'
# Fail-closed prüfen: keine Remote-/AI-Bindings mehr drin, SKIP_ACCESS gesetzt
if grep -q '"remote"' wrangler.local.jsonc; then
  echo "FEHLER: wrangler.local.jsonc enthält noch remote-Bindings:" >&2
  grep -n '"remote"' wrangler.local.jsonc >&2
  exit 1
fi
if grep -q '"ai"' wrangler.local.jsonc; then
  echo "FEHLER: wrangler.local.jsonc enthält noch ein ai-Binding:" >&2
  grep -n '"ai"' wrangler.local.jsonc >&2
  exit 1
fi
grep -q '"SKIP_ACCESS"' wrangler.local.jsonc || {
  echo "FEHLER: SKIP_ACCESS fehlt in wrangler.local.jsonc" >&2
  exit 1
}
echo "  - wrangler.local.jsonc: keine remote-/ai-Bindings, SKIP_ACCESS=1 (login-frei)."
# vite-Plugin auf die Lokal-Config zeigen (idempotent, fail-closed).
# WICHTIG: Guard mit Doppelpunkt — bloßes "configPath" matcht auch "tsconfigPaths"!
if ! grep -qE 'configPath\s*:' vite.config.ts; then
  sed -i 's|cloudflare({ viteEnvironment:|cloudflare({ configPath: "wrangler.local.jsonc", viteEnvironment:|' vite.config.ts
fi
grep -qE 'configPath\s*:\s*"wrangler.local.jsonc"' vite.config.ts || {
  echo "FEHLER: configPath-Patch in vite.config.ts fehlgeschlagen (Upstream-Format geändert?)." >&2
  grep -n 'cloudflare(' vite.config.ts >&2 || true
  exit 1
}
echo "  - vite.config.ts nutzt wrangler.local.jsonc."
# Access-Bypass für lokalen Build (idempotent, fail-closed).
# Ohne ihn antwortet der Production-Build überall mit
# "Cloudflare Access must be configured in production" (HTTP 500).
if ! grep -q 'SKIP_ACCESS' workers/app.ts; then
  node -e '
const fs = require("fs");
const f = "workers/app.ts";
let s = fs.readFileSync(f, "utf8");
const anchor = "\t// Skip validation in development\n\tif (import.meta.env.DEV) {\n\t\treturn next();\n\t}\n";
if (!s.includes(anchor)) {
  console.error("FEHLER: Anker in workers/app.ts nicht gefunden (Upstream-Format geändert?)");
  process.exit(1);
}
const patch = anchor + "\n\t// Lokale LXC-Emulation (nur aktiv wenn wrangler.local.jsonc SKIP_ACCESS=1 setzt)\n\tif ((c.env as unknown as Record<string, string | undefined>).SKIP_ACCESS === \"1\") {\n\t\treturn next();\n\t}\n";
s = s.replace(anchor, patch);
fs.writeFileSync(f, s);
console.log("workers/app.ts Bypass gesetzt");
'
fi
grep -q 'SKIP_ACCESS' workers/app.ts || {
  echo "FEHLER: SKIP_ACCESS-Bypass fehlt in workers/app.ts" >&2
  exit 1
}
echo "  - workers/app.ts Bypass aktiv."

echo "[5/9] Production-Build (npm run build, idempotent) ..."
npm run build
[[ -f "${BUILD_DIR}/index.js" && -f "${BUILD_DIR}/wrangler.json" ]] || {
  echo "FEHLER: Build unvollständig (build/server/index.js oder wrangler.json fehlt)." >&2
  exit 1
}
# Gebaute Config muss lokal servierbar sein (kein remote/ai) + SKIP_ACCESS haben
if grep -q '"remote"' "${BUILD_DIR}/wrangler.json"; then
  echo "FEHLER: build/server/wrangler.json enthält remote-Bindings (configPath-Patch unwirksam?)." >&2
  exit 1
fi
grep -q 'SKIP_ACCESS' "${BUILD_DIR}/wrangler.json" || {
  echo "FEHLER: build/server/wrangler.json ohne SKIP_ACCESS." >&2
  exit 1
}
echo "  - Build OK, lokal servierbar."

echo "[6/9] systemd-Units installieren ..."
for svc in "${APP_SERVICE}.service" "${SETUP_SERVICE}.service"; do
  src=""
  if [[ -f "${REPO_FILES_DIR}/systemd/${svc}" ]]; then
    src="${REPO_FILES_DIR}/systemd/${svc}"
  elif [[ -f "./systemd/${svc}" ]]; then
    src="./systemd/${svc}"
  fi
  if [[ -n "${src}" ]]; then
    cp "${src}" "/etc/systemd/system/${svc}"
  else
    echo "WARN: Unit-Quelle ${svc} nicht gefunden (repo-files/systemd/)" >&2
  fi
done
# Ports in Units sicherstellen (neutral gegenüber Template-Abweichungen)
sed -i -E "s/--port [0-9]+/--port ${WEB_PORT}/g" "/etc/systemd/system/${APP_SERVICE}.service" || true
sed -i -E "s/^Environment=AI_APP_PORT=.*/Environment=AI_APP_PORT=${WEB_PORT}/" "/etc/systemd/system/${SETUP_SERVICE}.service" || true
sed -i -E "s/^Environment=AI_SETUP_PORT=.*/Environment=AI_SETUP_PORT=${SETUP_PORT}/" "/etc/systemd/system/${SETUP_SERVICE}.service" || true
node --check "${PORTAL_DIR}/server.mjs"
systemctl daemon-reload
systemctl enable "${APP_SERVICE}" "${SETUP_SERVICE}"
systemctl restart "${APP_SERVICE}" "${SETUP_SERVICE}"

echo "[7/9] Firewall-Hinweis (LXC hat i. d. R. keine aktive FW) ..."
if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "active"; then
  ufw allow "${WEB_PORT}/tcp" || true
  ufw allow "${SETUP_PORT}/tcp" || true
fi

echo "[8/9] Verifikation ..."
sleep 8
echo "  - Service ${APP_SERVICE}: $(systemctl is-active "${APP_SERVICE}")"
echo "  - Service ${SETUP_SERVICE}: $(systemctl is-active "${SETUP_SERVICE}")"
systemctl is-active --quiet "${APP_SERVICE}" || {
  echo "Service ${APP_SERVICE} läuft NICHT. Journal:" >&2
  journalctl -u "${APP_SERVICE}" --no-pager -n 100 >&2
  exit 1
}
systemctl is-active --quiet "${SETUP_SERVICE}" || {
  echo "Service ${SETUP_SERVICE} läuft NICHT. Journal:" >&2
  journalctl -u "${SETUP_SERVICE}" --no-pager -n 100 >&2
  exit 1
}
echo "  - HTTP-Check App auf localhost:${WEB_PORT} ..."
app_ok=0
for i in $(seq 1 20); do
  code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${WEB_PORT}/" 2>&1 || echo 000)"
  if [[ "${code}" =~ ^[2345][0-9][0-9]$ && "${code}" != "000" ]]; then
    echo "  - App antwortet (HTTP ${code})."
    app_ok=1
    break
  fi
  if [[ "$i" == "20" ]]; then
    echo "App antwortet NICHT (letzter Code: ${code}). Journal + curl -v:" >&2
    journalctl -u "${APP_SERVICE}" --no-pager -n 100 >&2
    curl -v "http://127.0.0.1:${WEB_PORT}/" >&2 || true
    exit 1
  fi
  sleep 3
done
[[ "${app_ok}" == "1" ]]
echo "  - HTTP-Check API auf localhost:${WEB_PORT}/api/v1/mailboxes (muss 200 liefern) ..."
curl -fsS "http://127.0.0.1:${WEB_PORT}/api/v1/mailboxes" && echo && echo "  - API antwortet."
echo "  - HTTP-Check Setup-Portal auf localhost:${SETUP_PORT}/healthz ..."
curl -fsS "http://127.0.0.1:${SETUP_PORT}/healthz" && echo && echo "  - Setup-Portal antwortet."

CT_IP="$(hostname -I | awk '{print $1}')"
echo "[9/9] Fertig."
echo "=================================================================="
echo " Agentic Inbox (lokaler Build):      http://${CT_IP}:${WEB_PORT}"
echo " Setup-Portal (alles einstellen) : http://${CT_IP}:${SETUP_PORT}"
echo " Daten (R2/DO, reboot-sicher)    : ${STATE_DIR}"
echo " Services: systemctl status ${APP_SERVICE} ${SETUP_SERVICE}"
echo "=================================================================="
