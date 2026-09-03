const FORMATS = [
  ["cpa", "CPA"],
  ["codex", "Codex auth.json"],
  ["sub2api", "sub2api"],
  ["cockpit", "Cockpit"],
  ["9router", "9router"],
  ["axonhub", "AxonHub"],
  ["codexmanager", "Codex-Manager"],
];

const STEP_LABEL = {
  queued: "đang chờ worker",
  parse: "đọc dòng",
  login: "đang login",
  oauth: "đang OAuth Codex",
  refresh: "đang refresh token",
  export: "đang ghi JSON",
  done: "xong",
};

const STORE_KEY = "gpt-tool-ui";

function loadPrefs() {
  try {
    return JSON.parse(localStorage.getItem(STORE_KEY) || "{}") || {};
  } catch {
    return {};
  }
}

function savePrefs() {
  const fmt = selectedFormat();
  localStorage.setItem(
    STORE_KEY,
    JSON.stringify({
      format: fmt,
      proxy: document.getElementById("proxy").value,
      workers: clampWorkers(document.getElementById("workers").value),
    })
  );
}

function clampWorkers(value) {
  const n = Number(value);
  if (!Number.isFinite(n)) return 2;
  return Math.max(1, Math.min(8, Math.round(n)));
}

const formatsEl = document.getElementById("formats");
FORMATS.forEach(([id, label]) => {
  const el = document.createElement("label");
  el.innerHTML = `<input type="radio" name="fmt" value="${id}"> ${label}`;
  formatsEl.appendChild(el);
});

const prefs = loadPrefs();
if (prefs.format) {
  const radio = document.querySelector(`input[name="fmt"][value="${prefs.format}"]`);
  if (radio) radio.checked = true;
}
if (prefs.proxy) document.getElementById("proxy").value = prefs.proxy;
document.getElementById("workers").value = clampWorkers(prefs.workers ?? document.getElementById("workers").value);
document.getElementById("formats").addEventListener("change", savePrefs);
document.getElementById("proxy").addEventListener("change", savePrefs);
document.getElementById("workers").addEventListener("change", () => {
  document.getElementById("workers").value = clampWorkers(document.getElementById("workers").value);
  savePrefs();
});

function selectedFormat() {
  const el = document.querySelector('input[name="fmt"]:checked');
  return el ? el.value : "";
}

const rows = new Map();

function setStatus(text, cls) {
  const el = document.getElementById("status");
  el.hidden = !text;
  el.className = "log-banner " + (cls || "");
  el.textContent = text || "";
}

function jobLines(text) {
  return String(text || "")
    .split("\n")
    .map((line) => line.trim())
    .filter((raw) => raw && !raw.startsWith("#"));
}

function seedRows(text) {
  rows.clear();
  jobLines(text).forEach((line, index) => {
    const email = line.split("|")[0].trim().toLowerCase();
    if (!email) return;
    rows.set(String(index), { email, state: "queued", step: "queued", index });
  });
}

function applyJob(running, results) {
  const finished = new Set();
  (results || []).forEach((item, i) => {
    const key = item.index != null ? String(item.index) : String(i);
    finished.add(key);
    rows.set(key, {
      email: item.email,
      state: item.ok ? "ok" : "fail",
      step: item.ok ? "done" : item.step || "fail",
      path: item.path,
      error: item.error,
      index: item.index != null ? item.index : i,
    });
  });
  const live = new Set();
  Object.entries(running || {}).forEach(([key, val]) => {
    const rec = val && typeof val === "object" ? val : { email: key, step: val };
    const id = rec.index != null ? String(rec.index) : String(key);
    if (finished.has(id)) return;
    live.add(id);
    const prev = rows.get(id) || { email: rec.email || key };
    rows.set(id, {
      ...prev,
      email: rec.email || prev.email,
      state: "run",
      step: rec.step || val,
    });
  });
  for (const [id, row] of rows) {
    if (finished.has(id) || live.has(id) || row.state !== "run") continue;
    rows.set(id, { ...row, state: "queued", step: "queued" });
  }
}

function renderLog(total, busy) {
  const list = document.getElementById("line-log");
  const items = [...rows.values()];
  const ok = items.filter((row) => row.state === "ok").length;
  const fail = items.filter((row) => row.state === "fail").length;
  const done = ok + fail;
  const all = total || items.length;
  document.getElementById("log-spinner").hidden = !busy;
  const progress = document.getElementById("log-progress");
  const bar = document.getElementById("log-bar");
  progress.hidden = !all;
  bar.style.width = all ? `${Math.round((done / all) * 100)}%` : "0%";
  const summary = document.getElementById("live-summary");
  const running = items.filter((row) => row.state === "run").length;
  const slots = clampWorkers(document.getElementById("workers").value);
  if (busy) summary.textContent = `${done}/${all} · ${running}/${slots} worker · ${ok} OK · ${fail} lỗi`;
  else if (all) summary.textContent = `Xong ${done}/${all} · ${ok} OK · ${fail} lỗi`;
  else summary.textContent = "Chưa chạy.";
  list.innerHTML = items
    .map((row) => {
      const pill = STEP_LABEL[row.step] || row.step || "";
      const detail = row.state === "ok" ? row.path || "đã ghi file" : row.error || "";
      return `<li class="log-row ${row.state}">
        <span class="dot"></span>
        <div>
          <div class="email">${escapeHtml(row.email)}</div>
          ${detail ? `<div class="meta">${escapeHtml(detail)}</div>` : ""}
        </div>
        <span class="pill">${escapeHtml(pill)}</span>
      </li>`;
    })
    .join("");
}

function escapeHtml(value) {
  return String(value)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function renderResults(results, total, busy) {
  applyJob({}, results);
  renderLog(total || results.length, !!busy);
}

document.querySelectorAll(".tabs button").forEach((btn) => {
  btn.addEventListener("click", () => {
    document.querySelectorAll(".tabs button").forEach((b) => b.classList.remove("active"));
    btn.classList.add("active");
    const tab = btn.dataset.tab;
    document.getElementById("tab-export").classList.toggle("hidden", tab !== "export");
    document.getElementById("tab-convert").classList.toggle("hidden", tab !== "convert");
  });
});

const runExport = document.getElementById("run-export");

document.getElementById("run-export").addEventListener("click", async () => {
  const format = selectedFormat();
  if (!format) {
    setStatus("Chọn định dạng ở bước 1 trước khi chạy.", "err");
    return;
  }
  if (!confirm("Token xuất ra là mật khẩu đăng nhập. Chỉ dùng trên máy của bạn. Tiếp tục?")) return;
  savePrefs();
  runExport.disabled = true;
  seedRows(document.getElementById("lines").value);
  renderLog(rows.size, true);
  setStatus("");
  const res = await fetch("/api/export", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      format,
      lines: document.getElementById("lines").value,
      proxy: document.getElementById("proxy").value,
      workers: clampWorkers(document.getElementById("workers").value),
    }),
  });
  const data = await res.json();
  if (!res.ok) {
    runExport.disabled = false;
    renderLog(rows.size, false);
    setStatus(data.error || "export lỗi", "err");
    return;
  }
  const id = data.id;
  const poll = async () => {
    const job = await (await fetch("/api/jobs/" + id)).json();
    const results = job.results || [];
    const total = job.total || rows.size;
    applyJob(job.running || {}, results);
    renderLog(total, !job.done);
    if (!job.done) {
      setTimeout(poll, 400);
      return;
    }
    runExport.disabled = false;
    if (job.error) setStatus(job.error, "err");
  };
  poll();
});

document.getElementById("run-convert").addEventListener("click", async () => {
  const format = selectedFormat();
  if (!format) {
    setStatus("Chọn định dạng ở bước 1 trước khi chạy.", "err");
    return;
  }
  rows.clear();
  renderLog(0, true);
  setStatus("");
  const res = await fetch("/api/convert", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ format, text: document.getElementById("json-in").value }),
  });
  const data = await res.json();
  if (!res.ok) {
    renderLog(0, false);
    setStatus(data.error || "convert lỗi", "err");
    return;
  }
  rows.clear();
  renderResults(data.results || [], (data.results || []).length, false);
});

document.getElementById("open-out").addEventListener("click", async () => {
  await fetch("/api/open-out", { method: "POST", headers: { "Content-Type": "application/json" }, body: "{}" });
});
