#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

if ! command -v python3 >/dev/null 2>&1; then
  echo "Cần Python 3.11+ . Tải tại https://www.python.org/downloads/"
  exit 1
fi
if ! python3 -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 11) else 1)'; then
  echo "Cần Python 3.11+ (hiện tại: $(python3 -c 'import sys; print(sys.version.split()[0])'))"
  echo "Tải tại https://www.python.org/downloads/"
  exit 1
fi

if [ ! -d .venv ]; then
  echo "Đang tạo môi trường (.venv)…"
  python3 -m venv .venv
fi

# shellcheck disable=SC1091
source .venv/bin/activate
echo "Đang tải / cập nhật thư viện (lần đầu 1–2 phút)…"
python -m pip install -q -U pip
python -m pip install -q -U -r requirements.txt
python -c "from gpt_tool.ensure_deps import ensure_deps; ensure_deps()"
echo "Mở GPT-Tool trên trình duyệt…"
exec python -m gpt_tool.server
