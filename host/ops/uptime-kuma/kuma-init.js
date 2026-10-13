// Runs INSIDE the uptime-kuma container: `docker exec -i <c> node /dev/stdin`
// is avoided so credentials can arrive on stdin; the script is copied in.
// stdin: {"user":..., "password":...}  (empty stdin = check only)
// exit 0 = initialised (or now set up), 3 = needs setup (check mode), other = error
const { io } = require("/app/node_modules/socket.io-client");
let input = "";
process.stdin.on("data", (d) => (input += d)).on("end", () => {
  const creds = input.trim() ? JSON.parse(input) : null;
  const s = io("http://127.0.0.1:3001", { transports: ["websocket"], reconnection: false, timeout: 10000 });
  const done = (code, msg) => { console.log(msg); s.close(); process.exit(code); };
  setTimeout(() => done(4, "timeout"), 30000);
  s.on("connect_error", (e) => done(2, "connect_error " + e.message));
  s.on("connect", () => {
    s.emit("needSetup", (need) => {
      if (!need) return done(0, "already-initialised");
      if (!creds) return done(3, "needs-setup");
      s.emit("setup", creds.user, creds.password, (res) =>
        res && res.ok ? done(0, "setup-ok") : done(1, "setup-failed " + (res && res.msg)));
    });
  });
});
