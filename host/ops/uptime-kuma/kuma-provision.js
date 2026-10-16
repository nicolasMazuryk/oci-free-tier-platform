// Idempotent Uptime Kuma provisioning. Runs INSIDE the container (copied in by bootstrap.sh):
//   docker exec -i <ctr> node /tmp/kuma-provision.js < input.json
// input: {user, password, domain, cloudIp, alertsTo, smtp:{host,port,username,password,from}|null, test:false}
// Ensures (matched by name/slug, never duplicated):
//   - SMTP notification "core-email" (default, applied to all monitors)
//   - the standard monitor set below (a `renamedFrom` monitor is renamed in place, keeping its history)
//   - public status page "core" with those monitors, set as the entry page
// Auth is NOT disabled: /dashboard stays behind login.
const { io } = require("/app/node_modules/socket.io-client");

let input = "";
process.stdin.on("data", (d) => (input += d)).on("end", () => main(JSON.parse(input)).catch((e) => fail(e.message || String(e))));

let sock;
function fail(msg) { console.log("ERROR " + msg); if (sock) sock.close(); process.exit(1); }
const emit = (ev, ...args) => new Promise((res, rej) => {
  const t = setTimeout(() => rej(new Error(ev + " timeout")), 30000);
  sock.emit(ev, ...args, (r) => { clearTimeout(t); r && r.ok === false ? rej(new Error(ev + ": " + r.msg)) : res(r); });
});

function monitorDefaults() {
  return {
    method: "GET", interval: 60, retryInterval: 60, resendInterval: 0, maxretries: 2, timeout: 30,
    ignoreTls: false, upsideDown: false, expiryNotification: false, maxredirects: 10,
    accepted_statuscodes: ["200-299"], dns_resolve_type: "A", dns_resolve_server: "1.1.1.1",
    docker_container: "", docker_host: null, proxyId: null, httpBodyEncoding: "json",
    kafkaProducerBrokers: [], kafkaProducerSaslOptions: { mechanism: "None" }, kafkaProducerSsl: false,
    kafkaProducerAllowAutoTopicCreation: false, gamedigGivenPortOnly: true, conditions: [], rabbitmqNodes: [],
    packetSize: 56, description: "",
  };
}

function wanted(cfg) {
  const d = cfg.domain;
  return [
    { group: "Sites", name: `${d}`, type: "keyword", url: `https://${d}`, keyword: "core edge: ok",
      description: "Apex through Cloudflare -> core-nlb -> Caddy" },
    { group: "Sites", name: `status.${d}`, type: "http", url: `https://status.${d}/status/core`,
      description: "This status page through Cloudflare (Caddy -> ops)" },
    { group: "Origin", name: "core-vm-cloud origin :443 (private)", type: "port", hostname: cfg.cloudIp, port: 443,
      renamedFrom: "core-vm-app origin :443 (private)",
      description: "Caddy on core-vm-cloud over the private network (bypasses Cloudflare/NLB)" },
    { group: "Dependencies", name: "GitHub", type: "http", url: "https://github.com", interval: 300,
      description: "Agent fleet dependency (git over HTTPS)" },
    { group: "Dependencies", name: "Anthropic API", type: "http", url: "https://api.anthropic.com",
      accepted_statuscodes: ["200-499"], interval: 300,
      description: "Agent fleet dependency (any HTTP answer = reachable)" },
  ];
}

async function main(cfg) {
  sock = io("http://127.0.0.1:3001", { transports: ["websocket"], reconnection: false, timeout: 15000 });
  const lists = {};
  for (const ev of ["monitorList", "notificationList", "statusPageList"]) sock.on(ev, (v) => (lists[ev] = v));
  await new Promise((res, rej) => { sock.on("connect", res); sock.on("connect_error", (e) => rej(e)); });
  await emit("login", { username: cfg.user, password: cfg.password, token: "" });
  const waitLists = async () => { for (let i = 0; i < 100 && !(lists.monitorList && lists.notificationList && lists.statusPageList); i++) await new Promise((r) => setTimeout(r, 100)); };
  await waitLists();
  if (!lists.monitorList) throw new Error("no monitorList after login");

  // 1. notification
  let notifId = null;
  if (cfg.smtp) {
    const existing = (lists.notificationList || []).find((n) => n.name === "core-email");
    const notif = {
      name: "core-email", type: "smtp", isDefault: true, applyExisting: true, active: true,
      smtpHost: cfg.smtp.host, smtpPort: cfg.smtp.port, smtpSecure: false, smtpIgnoreTLSError: false,
      smtpUsername: cfg.smtp.username, smtpPassword: cfg.smtp.password,
      smtpFrom: `core status <${cfg.smtp.from}>`, smtpTo: cfg.alertsTo,
    };
    if (existing) { notifId = existing.id; console.log("notification core-email exists (id " + notifId + ")"); }
    else { const r = await emit("addNotification", notif, null); notifId = r.id; console.log("created notification core-email (id " + notifId + ")"); }
    if (cfg.test) { await emit("testNotification", notif); console.log("test email sent"); }
  }

  // 2. monitors (match by name; rename `renamedFrom` in place; create missing only)
  const byName = Object.fromEntries(Object.values(lists.monitorList).map((m) => [m.name, m]));
  const ids = {};
  for (const w of wanted(cfg)) {
    const { group, renamedFrom, ...spec } = w;
    if (byName[w.name]) { ids[w.name] = byName[w.name].id; console.log("monitor exists: " + w.name); continue; }
    const old = renamedFrom && byName[renamedFrom];
    if (old) {
      try {
        await emit("editMonitor", { ...old, ...spec });
        ids[w.name] = old.id; console.log("renamed monitor: " + renamedFrom + " -> " + w.name + " (id " + old.id + ")");
        continue;
      } catch (e) { console.log("WARN rename failed (" + e.message + "): creating " + w.name + "; delete '" + renamedFrom + "' by hand"); }
    }
    const m = { ...monitorDefaults(), ...spec, notificationIDList: notifId ? { [notifId]: true } : {} };
    const r = await emit("add", m);
    ids[w.name] = r.monitorID; console.log("created monitor: " + w.name + " (id " + r.monitorID + ")");
  }

  // 3. status page "core"
  const slug = "core";
  const sp = Object.values(lists.statusPageList || {}).find((p) => p.slug === slug);
  if (!sp) { await emit("addStatusPage", `${cfg.domain.split(".")[0]} status`, slug); console.log("created status page " + slug); }
  else console.log("status page exists: " + slug);
  const groups = [];
  for (const w of wanted(cfg)) {
    let g = groups.find((x) => x.name === w.group);
    if (!g) { g = { name: w.group, monitorList: [] }; groups.push(g); }
    g.monitorList.push({ id: ids[w.name] });
  }
  const config = {
    slug, title: `${cfg.domain.split(".")[0]} status`, description: `Live status of ${cfg.domain} services`,
    autoRefreshInterval: 300, theme: "auto", showTags: false, footerText: "Managed by oci-infra (host/ops/uptime-kuma)",
    customCSS: "", showPoweredBy: false, rssTitle: null, showOnlyLastHeartbeat: false, showCertificateExpiry: true,
    analyticsId: null, analyticsScriptUrl: null, analyticsType: null, domainNameList: [],
  };
  await emit("saveStatusPage", slug, config, "/icon.svg", groups);
  console.log("status page " + slug + " saved (" + groups.map((g) => g.name + ":" + g.monitorList.length).join(", ") + ")");

  // 4. entry page -> status page (login still required for /dashboard)
  const s = await emit("getSettings");
  if (s.data.entryPage !== "statusPage-" + slug || s.data.disableAuth) {
    s.data.entryPage = "statusPage-" + slug;
    s.data.disableAuth = false;
    await emit("setSettings", s.data, cfg.password);
    console.log("entryPage set to statusPage-" + slug);
  } else console.log("entryPage already statusPage-" + slug);

  sock.close(); console.log("provision-ok"); process.exit(0);
}
