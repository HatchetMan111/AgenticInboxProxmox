#!/usr/bin/env node
/**
 * agentic-inbox Setup-Portal — Mini Config-WebUI ohne npm-Dependencies.
 * Port: 8081 (APP läuft auf 8080). Bind: 0.0.0.0. Läuft als systemd-Service.
 *
 * Kann einstellen:
 *  - DOMAINS (wrangler.jsonc -> vars.DOMAINS)
 *  - POLICY_AUD / TEAM_DOMAIN (.dev.vars, Cloudflare Access, für späteren Deploy)
 *  - Service-Restart der App, Status + Log-Tail
 */
import http from "node:http";
import fs from "node:fs";
import { execFile } from "node:child_process";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

const APP_DIR = process.env.AI_APP_DIR || "/opt/agentic-inbox/app";
const WRANGLER_FILE = `${APP_DIR}/wrangler.jsonc`;
const DEV_VARS_FILE = `${APP_DIR}/.dev.vars`;
const APP_SERVICE = process.env.AI_APP_SERVICE || "agentic-inbox";
const APP_PORT = Number(process.env.AI_APP_PORT || 8080);
const PORT = Number(process.env.AI_SETUP_PORT || 8081);

function readTextSafe(path) {
  try {
    return fs.readFileSync(path, "utf8");
  } catch {
    return "";
  }
}

function getDomains() {
  const raw = readTextSafe(WRANGLER_FILE);
  const m = raw.match(/"DOMAINS"\s*:\s*"([^"]*)"/);
  return m ? m[1] : "example.com";
}

function setDomains(raw, domains) {
  if (/"DOMAINS"\s*:/.test(raw)) {
    return raw.replace(/"DOMAINS"\s*:\s*"[^"]*"/, `"DOMAINS": "${domains}"`);
  }
  return raw.replace(/"vars"\s*:\s*{/, `"vars": {\n\t\t"DOMAINS": "${domains}",`);
}

function parseDevVars(raw) {
  const out = {};
  for (const line of raw.split("\n")) {
    const m = line.match(/^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)\s*$/);
    if (m) out[m[1]] = m[2];
  }
  return out;
}

function serializeDevVars(obj) {
  return Object.entries(obj)
    .map(([k, v]) => `${k}=${v}`)
    .join("\n") + "\n";
}

async function serviceActive(name) {
  try {
    await execFileAsync("systemctl", ["is-active", "--quiet", name]);
    return true;
  } catch {
    return false;
  }
}

async function journalTail(name, lines = 30) {
  try {
    const { stdout } = await execFileAsync("journalctl", [
      "-u", name, "--no-pager", "-n", String(lines),
    ]);
    return stdout.slice(-6000);
  } catch (e) {
    return `journalctl fehlgeschlagen: ${e.message}`;
  }
}

function esc(s) {
  return String(s ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

function page({ domains, policyAud, teamDomain, appActive, portalActive, msg }) {
  return `<!doctype html><html lang="de"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Agentic Inbox — Setup</title>
<style>
body{font-family:system-ui,sans-serif;max-width:760px;margin:2rem auto;padding:0 1rem;background:#0b0f14;color:#e6edf3}
.card{background:#161b22;border:1px solid #30363d;border-radius:10px;padding:1.2rem;margin-bottom:1rem}
input{width:100%;padding:.6rem;margin:.3rem 0 .8rem;border-radius:6px;border:1px solid #30363d;background:#0d1117;color:#e6edf3}
button{padding:.6rem 1rem;border-radius:6px;border:0;background:#238636;color:#fff;cursor:pointer;margin-right:.5rem}
button.ghost{background:#30363d}
.badge{display:inline-block;padding:.2rem .6rem;border-radius:99px;font-size:.85rem}
.ok{background:#1a7f37}.bad{background:#da3633}
pre{white-space:pre-wrap;background:#0d1117;padding:.8rem;border-radius:6px;max-height:300px;overflow:auto}
a{color:#58a6ff}
small{color:#8b949e}
</style></head><body>
<h1>📥 Agentic Inbox — Setup-Portal</h1>
<p><small>Lokal-Emulation im LXC · App auf Port ${APP_PORT} · Portal auf Port ${PORT}</small></p>
${msg ? `<div class="card">${msg}</div>` : ""}
<div class="card">
<h2>Status</h2>
<p>App-Service <code>${esc(APP_SERVICE)}</code>:
<span class="badge ${appActive ? "ok" : "bad"}">${appActive ? "active" : "NICHT aktiv"}</span></p>
<p>Setup-Portal:
<span class="badge ${portalActive ? "ok" : "bad"}">${portalActive ? "active" : "?"}</span></p>
<p>App-Web-UI: <a href="http://__HOST__:${APP_PORT}/">http://&lt;LXC-IP&gt;:${APP_PORT}/</a></p>
</div>
<div class="card">
<h2>Konfiguration</h2>
<form method="POST" action="/save">
<label>DOMAINS <small>(Empfangs-Domain, z. B. example.com — landet in wrangler.jsonc)</small></label>
<input name="domains" value="${esc(domains)}" required>
<label>POLICY_AUD <small>(Cloudflare Access, nur für späteren Deploy nötig)</small></label>
<input name="policyAud" value="${esc(policyAud)}" placeholder="optional für lokale Emulation">
<label>TEAM_DOMAIN <small>(z. B. https://team.cloudflareaccess.com)</small></label>
<input name="teamDomain" value="${esc(teamDomain)}" placeholder="optional für lokale Emulation">
<button type="submit">Speichern</button>
</form>
<form method="POST" action="/restart" style="margin-top:.6rem">
<button class="ghost" type="submit">App-Service neu starten</button>
</form>
</div>
<div class="card"><h2>Hinweis: lokal vs. Cloudflare</h2>
<p>Dieses LXC-Setup fährt die <b>lokale Emulation</b> (<code>npm run dev</code>):
UI + Entwicklung funktionieren sofort im LAN. Echter Mail-Empfang/-Versand
(Email Routing, R2, Workers AI, Access) braucht danach ein
<code>npm run deploy</code> auf einen Cloudflare-Account mit Domain.</p>
</div>
<div class="card"><h2>App-Log (letzte Zeilen)</h2>
<form method="GET" action="/"><button class="ghost" type="submit">Aktualisieren</button></form>
<pre id="log">wird geladen …</pre>
<script>fetch("/api/logs").then(r=>r.text()).then(t=>document.getElementById("log").textContent=t);</script>
</div>
</body></html>`;
}

function parseForm(body) {
  const out = {};
  for (const part of body.split("&")) {
    const [k, v] = part.split("=");
    if (k) out[decodeURIComponent(k)] = decodeURIComponent((v || "").replaceAll("+", " "));
  }
  return out;
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, "http://localhost");
  try {
    if (req.method === "GET" && url.pathname === "/healthz") {
      res.writeHead(200, { "content-type": "application/json" });
      res.end(JSON.stringify({ status: "ok", service: "agentic-inbox-setup" }));
      return;
    }
    if (req.method === "GET" && url.pathname === "/api/status") {
      const devVars = parseDevVars(readTextSafe(DEV_VARS_FILE));
      res.writeHead(200, { "content-type": "application/json" });
      res.end(JSON.stringify({
        status: "ok",
        domains: getDomains(),
        hasPolicyAud: Boolean(devVars.POLICY_AUD),
        hasTeamDomain: Boolean(devVars.TEAM_DOMAIN),
        appActive: await serviceActive(APP_SERVICE),
        appPort: APP_PORT,
      }));
      return;
    }
    if (req.method === "GET" && url.pathname === "/api/logs") {
      res.writeHead(200, { "content-type": "text/plain; charset=utf-8" });
      res.end(await journalTail(APP_SERVICE));
      return;
    }
    if (req.method === "POST" && url.pathname === "/save") {
      let body = "";
      for await (const c of req) body += c;
      const f = parseForm(body);
      const domains = (f.domains || "").trim() || "example.com";
      // wrangler.jsonc aktualisieren
      const raw = readTextSafe(WRANGLER_FILE);
      if (!raw) throw new Error(`wrangler.jsonc nicht gefunden: ${WRANGLER_FILE}`);
      fs.writeFileSync(WRANGLER_FILE, setDomains(raw, domains));
      // .dev.vars aktualisieren (nur gesetzte Felder anfassen)
      const dv = parseDevVars(readTextSafe(DEV_VARS_FILE));
      if ((f.policyAud || "").trim()) dv.POLICY_AUD = f.policyAud.trim();
      if ((f.teamDomain || "").trim()) dv.TEAM_DOMAIN = f.teamDomain.trim();
      fs.writeFileSync(DEV_VARS_FILE, serializeDevVars(dv), { mode: 0o600 });
      res.writeHead(303, { location: "/?saved=1" });
      res.end();
      return;
    }
    if (req.method === "POST" && url.pathname === "/restart") {
      // Body verwerfen
      for await (const _ of req) { /* drain */ }
      try {
        await execFileAsync("systemctl", ["restart", APP_SERVICE]);
      } catch (e) {
        res.writeHead(500, { "content-type": "text/plain; charset=utf-8" });
        res.end(`Restart fehlgeschlagen (Exit != 0):\n${e.stdout || ""}\n${e.stderr || e.message}`);
        return;
      }
      res.writeHead(303, { location: "/?restarted=1" });
      res.end();
      return;
    }
    if (req.method === "GET" && (url.pathname === "/" || url.pathname === "/index.html")) {
      const devVars = parseDevVars(readTextSafe(DEV_VARS_FILE));
      let msg = "";
      if (url.searchParams.get("saved") === "1") msg = "✅ Gespeichert. Bei Bedarf <b>App-Service neu starten</b>.";
      if (url.searchParams.get("restarted") === "1") msg = "🔄 Restart angestoßen — Status oben prüfen.";
      let html = page({
        domains: getDomains(),
        policyAud: devVars.POLICY_AUD || "",
        teamDomain: devVars.TEAM_DOMAIN || "",
        appActive: await serviceActive(APP_SERVICE),
        portalActive: true,
        msg,
      });
      html = html.replaceAll("__HOST__", esc(req.headers.host?.split(":")[0] || "LXC-IP"));
      res.writeHead(200, { "content-type": "text/html; charset=utf-8" });
      res.end(html);
      return;
    }
    res.writeHead(404, { "content-type": "text/plain" });
    res.end("not found");
  } catch (e) {
    // KOMPLETTE Fehlerkette, nie nur eine Zeile
    const detail = `Setup-Portal Fehler:\nmessage: ${e.message}\nstack:\n${e.stack || "(kein stack)"}`;
    console.error(detail);
    res.writeHead(500, { "content-type": "text/plain; charset=utf-8" });
    res.end(detail);
  }
});

server.listen(PORT, "0.0.0.0", () => {
  console.log(`agentic-inbox-setup listening on 0.0.0.0:${PORT} (app dir: ${APP_DIR})`);
});
