#!/usr/bin/env bash
# =============================================================================
# Agentic Inbox — Proxmox LXC Installer (Community-Scripts-Stil)
#
# Einzeiler (auf dem Proxmox-HOST als root ausführen):
#   bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/AgenticInboxProxmox/main/install/agentic-inbox.sh)"
#
# Was passiert:
#   1. Fragt CT-ID, Hostname, CPU/RAM/Disk, Storage, Netzwerk, Ports + DOMAINS ab
#   2. Erstellt einen Debian-12-LXC (onboot=1), startet ihn
#   3. Schiebt Wrapper-Dateien (portal/, systemd/, setup) in den Container
#   4. Installiert dort Agentic Inbox (lokale Emulation, npm run dev :8080)
#      + Setup-Portal (:8081, alles einstellbar) als systemd-Services
#   5. Verifiziert Services + HTTP und gibt die finalen URLs aus
#
# Idempotent: ist die CT-ID belegt, wird automatisch die nächste freie genommen.
# Update eines bestehenden Containers gezielt mit: CT_UPDATE=1 (als Env setzen).
# Debugging:  DEBUG=1 bash -x install/agentic-inbox.sh   (volles Trace-Log)
# =============================================================================
set -euo pipefail

# ============================ VARIABLEN (oben) ================================
APP="agentic-inbox"
GITHUB_USER="${GITHUB_USER:-HatchetMan111}"
GITHUB_REPO="${GITHUB_REPO:-AgenticInboxProxmox}"
GITHUB_BRANCH="${GITHUB_BRANCH:-main}"
RAW_BASE="https://raw.githubusercontent.com/${GITHUB_USER}/${GITHUB_REPO}/${GITHUB_BRANCH}"
TARBALL="https://github.com/${GITHUB_USER}/${GITHUB_REPO}/archive/refs/heads/${GITHUB_BRANCH}.tar.gz"

DEFAULT_CTID="${DEFAULT_CTID:-160}"
DEFAULT_HOSTNAME="${DEFAULT_HOSTNAME:-agenticinbox}"
DEFAULT_CORES="${DEFAULT_CORES:-2}"
DEFAULT_MEMORY="${DEFAULT_MEMORY:-2048}"     # MB
DEFAULT_DISK="${DEFAULT_DISK:-8}"            # GB
DEFAULT_STORAGE="${DEFAULT_STORAGE:-local-lvm}"
DEFAULT_TEMPLATE_STORAGE="${DEFAULT_TEMPLATE_STORAGE:-local}"
DEFAULT_BRIDGE="${DEFAULT_BRIDGE:-vmbr0}"
DEFAULT_WEB_PORT="${DEFAULT_WEB_PORT:-8080}"
DEFAULT_SETUP_PORT="${DEFAULT_SETUP_PORT:-8081}"
DEFAULT_DOMAINS="${DEFAULT_DOMAINS:-example.com}"
DEBIAN_TEMPLATE_PATTERN="debian-12-standard.*amd64.tar.zst"

# ========================= FEHLERKETTE (voll, nie 1 Zeile) =====================
fail() {
  local code=$?
  echo "==================================================================" >&2
  echo "[FATAL] Installation fehlgeschlagen (Exit-Code: ${code})" >&2
  echo "Befehl : ${BASH_COMMAND}" >&2
  echo "Zeile  : ${BASH_LINENO[0]:-?}" >&2
  echo "--- Funktions-Stack ---" >&2
  local i
  for ((i=0; i<${#FUNCNAME[@]}; i++)); do
    echo "  #${i} ${FUNCNAME[$i]:-main} @ ${BASH_SOURCE[$i]}:${BASH_LINENO[$i]:-?}" >&2
  done
  echo "--- Letzte pct-Auszüge (falls vorhanden) ---" >&2
  pct status "${CTID:-?}" 2>&1 | tail -n 20 >&2 || true
  echo "Tipp: Re-Run mit Trace: DEBUG=1 bash -x $0" >&2
  echo "==================================================================" >&2
  exit "${code}"
}
trap fail ERR
[[ "${DEBUG:-0}" == "1" ]] && set -x

# ================================ CHECKS ======================================
[[ "$(id -u)" == "0" ]] || { echo "Bitte als root auf dem Proxmox-Host ausführen." >&2; exit 1; }
command -v pct >/dev/null || { echo "pct nicht gefunden — kein Proxmox-Host?" >&2; exit 1; }
command -v pveam >/dev/null || { echo "pveam nicht gefunden — kein Proxmox-Host?" >&2; exit 1; }

ask() { # ask VAR "Prompt" "Default"  (whiptail wenn vorhanden, sonst read)
  local __var=$1 prompt=$2 def=$3 val
  if command -v whiptail >/dev/null; then
    val=$(whiptail --inputbox "${prompt}" 8 70 "${def}" 3>&1 1>&2 2>&3) || val="${def}"
  else
    read -rp "${prompt} [${def}]: " val; val="${val:-$def}"
  fi
  printf -v "${__var}" '%s' "${val}"
}

echo "=== ${APP} LXC-Installer (Proxmox VE Community-Scripts-Stil) ==="
echo "Modus: lokale Emulation (UI sofort nutzbar; echter Mailversand erst nach Cloudflare-Deploy)."
ask CTID        "Container-ID (CT-ID)"               "${DEFAULT_CTID}"
ask HOSTNAME    "Hostname"                           "${DEFAULT_HOSTNAME}"
ask CORES       "vCPU-Kerne"                         "${DEFAULT_CORES}"
ask MEMORY      "RAM in MB"                          "${DEFAULT_MEMORY}"
ask DISK        "Disk in GB"                         "${DEFAULT_DISK}"
ask STORAGE     "Storage für Disk (z. B. local-lvm)" "${DEFAULT_STORAGE}"
ask TPL_STORAGE "Storage für Templates"              "${DEFAULT_TEMPLATE_STORAGE}"
ask BRIDGE      "Netzwerk-Bridge"                    "${DEFAULT_BRIDGE}"
ask WEB_PORT    "App-Port (Agentic Inbox UI)"        "${DEFAULT_WEB_PORT}"
ask SETUP_PORT  "Setup-Portal-Port"                  "${DEFAULT_SETUP_PORT}"
ask DOMAINS     "DOMAINS (Empfangs-Domain, z. B. example.com)" "${DEFAULT_DOMAINS}"
ask POLICY_AUD  "POLICY_AUD (optional, nur für Cloudflare-Deploy)" ""
ask TEAM_DOMAIN "TEAM_DOMAIN (optional, nur für Cloudflare-Deploy)" ""

# --- CT-ID belegt? -> automatisch nächste freie nehmen ---------------------------
if pct status "${CTID}" >/dev/null 2>&1; then
  if [[ "${CT_UPDATE:-0}" == "1" ]]; then
    REUSE="update"
    echo "-> CT ${CTID} existiert, CT_UPDATE=1: Update-Modus (Container wird wiederverwendet)."
  else
    echo "-> CT ${CTID} ist belegt, suche nächste freie CT-ID ..."
    NEXT="${CTID}"
    for _ in $(seq 1 50); do
      NEXT=$((NEXT + 1))
      if ! pct status "${NEXT}" >/dev/null 2>&1; then
        break
      fi
    done
    if pct status "${NEXT}" >/dev/null 2>&1; then
      echo "Keine freie CT-ID im Bereich ${CTID}-$((CTID + 50)) gefunden." >&2
      exit 1
    fi
    echo "-> Nehme nächste freie CT-ID: ${NEXT} (statt ${CTID})"
    CTID="${NEXT}"
    REUSE="create"
  fi
else
  REUSE="create"
fi

# --- Template sicherstellen ----------------------------------------------------
echo "-> Suche Debian-12-Template in ${TPL_STORAGE} ..."
TEMPLATE="$(pveam list "${TPL_STORAGE}" 2>/dev/null | grep -oE "${DEBIAN_TEMPLATE_PATTERN}" | sort -V | tail -n 1 || true)"
if [[ -z "${TEMPLATE:-}" ]]; then
  echo "-> Kein Template gefunden, lade aktuelles (pveam update + download) ..."
  pveam update
  TEMPLATE="$(pveam available 2>/dev/null | grep -oE "${DEBIAN_TEMPLATE_PATTERN}" | sort -V | tail -n 1)"
  [[ -n "${TEMPLATE}" ]] || { echo "Kein Debian-12-Template verfügbar." >&2; exit 1; }
  pveam download "${TPL_STORAGE}" "${TEMPLATE}"
fi
echo "-> Template: ${TEMPLATE}"

# --- Container erstellen (nur wenn neu) ----------------------------------------
if [[ "${REUSE}" == "create" ]]; then
  echo "-> Erstelle LXC ${CTID} (${CORES} CPU / ${MEMORY} MB / ${DISK} GB) ..."
  pct create "${CTID}" "${TPL_STORAGE}:vztmpl/${TEMPLATE}" \
    --hostname "${HOSTNAME}" \
    --cores "${CORES}" --memory "${MEMORY}" \
    --rootfs "${STORAGE}:${DISK}" \
    --net0 "name=eth0,bridge=${BRIDGE},ip=dhcp" \
    --onboot 1 --start 1 \
    --unprivileged 1 \
    --features nesting=1
  # onboot doppelt absichern (Config-Key)
  grep -q "^onboot:" "/etc/pve/lxc/${CTID}.conf" \
    || echo "onboot: 1" >> "/etc/pve/lxc/${CTID}.conf"
  echo "-> Warte auf Container-Boot ..."
  sleep 8
else
  pct start "${CTID}" 2>/dev/null || true
  sleep 5
fi

pct exec "${CTID}" -- bash -c "echo Container erreichbar: \$(hostname) \$(hostname -I | awk '{print \$1}')"

# --- Wrapper-Dateien in den Container schieben ----------------------------------
WORKDIR="$(mktemp -d)"
cleanup() { rm -rf "${WORKDIR}"; }
trap 'cleanup; fail' ERR
echo "-> Lade Wrapper-Repo (${GITHUB_USER}/${GITHUB_REPO}@${GITHUB_BRANCH}) ..."
if command -v git >/dev/null; then
  git clone --depth 1 --branch "${GITHUB_BRANCH}" \
    "https://github.com/${GITHUB_USER}/${GITHUB_REPO}.git" "${WORKDIR}/repo"
else
  cd "${WORKDIR}" && wget -qO repo.tar.gz "${TARBALL}" && tar xzf repo.tar.gz
  mv "${WORKDIR}/${GITHUB_REPO}-${GITHUB_BRANCH}" "${WORKDIR}/repo"
fi

echo "-> Push nach CT:${CTID} ..."
pct exec "${CTID}" -- mkdir -p /opt/agentic-inbox/repo-files/systemd /opt/agentic-inbox/portal
pct push "${CTID}" "${WORKDIR}/repo/portal/server.mjs" /opt/agentic-inbox/portal/server.mjs
pct push "${CTID}" "${WORKDIR}/repo/systemd/agentic-inbox.service" \
  /opt/agentic-inbox/repo-files/systemd/agentic-inbox.service
pct push "${CTID}" "${WORKDIR}/repo/systemd/agentic-inbox-setup.service" \
  /opt/agentic-inbox/repo-files/systemd/agentic-inbox-setup.service
pct push "${CTID}" "${WORKDIR}/repo/install/setup-container.sh" \
  /opt/agentic-inbox/setup-container.sh
pct exec "${CTID}" -- chmod +x /opt/agentic-inbox/setup-container.sh

# --- Setup IM Container ausführen ------------------------------------------------
echo "-> Führe Setup im Container aus (dauert einige Minuten: Node 20 + npm ci) ..."
pct exec "${CTID}" -- env WEB_PORT="${WEB_PORT}" SETUP_PORT="${SETUP_PORT}" \
  DOMAINS="${DOMAINS}" POLICY_AUD="${POLICY_AUD}" TEAM_DOMAIN="${TEAM_DOMAIN}" \
  DEBUG="${DEBUG:-0}" \
  bash /opt/agentic-inbox/setup-container.sh

# --- Verifikation vom Host -------------------------------------------------------
echo "-> Verifikation ..."
pct exec "${CTID}" -- systemctl is-active --quiet agentic-inbox \
  || { echo "Service agentic-inbox läuft NICHT. Log:" >&2
       pct exec "${CTID}" -- journalctl -u agentic-inbox --no-pager -n 100 >&2
       exit 1; }
pct exec "${CTID}" -- systemctl is-active --quiet agentic-inbox-setup \
  || { echo "Service agentic-inbox-setup läuft NICHT. Log:" >&2
       pct exec "${CTID}" -- journalctl -u agentic-inbox-setup --no-pager -n 100 >&2
       exit 1; }
CT_IP="$(pct exec "${CTID}" -- hostname -I | awk '{print $1}')"
echo "-> HTTP-Check http://${CT_IP}:${WEB_PORT}/ ..."
curl -fsS "http://${CT_IP}:${WEB_PORT}/" -o /dev/null || {
  echo "HTTP-Check App fehlgeschlagen." >&2
  pct exec "${CTID}" -- journalctl -u agentic-inbox --no-pager -n 100 >&2
  exit 1
}
echo "-> HTTP-Check http://${CT_IP}:${SETUP_PORT}/healthz ..."
curl -fsS "http://${CT_IP}:${SETUP_PORT}/healthz" || {
  echo "HTTP-Check Setup-Portal fehlgeschlagen." >&2
  pct exec "${CTID}" -- journalctl -u agentic-inbox-setup --no-pager -n 100 >&2
  exit 1
}
cleanup
trap fail ERR

echo "=================================================================="
echo " ✅ Fertig! Agentic Inbox (lokale Emulation): http://${CT_IP}:${WEB_PORT}"
echo "    Setup-Portal (alles einstellen)          : http://${CT_IP}:${SETUP_PORT}"
echo "    CT-ID ${CTID} (${HOSTNAME}), onboot=1, Services=agentic-inbox + agentic-inbox-setup"
echo "    Neu    : Einzeiler erneut laufen lassen -> nächste freie CT-ID wird auto genommen"
echo "    Update : CT_UPDATE=1 bash -c \"\$(wget -qLO - https://raw.githubusercontent.com/${GITHUB_USER}/${GITHUB_REPO}/${GITHUB_BRANCH}/install/agentic-inbox.sh)\""
echo "    Logs   : pct exec ${CTID} -- journalctl -u agentic-inbox -f"
echo "    Löschen: pct stop ${CTID} && pct destroy ${CTID}"
echo "=================================================================="
