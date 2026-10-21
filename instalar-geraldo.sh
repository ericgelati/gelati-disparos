#!/usr/bin/env bash
# =============================================================================
# E. F. GELATI - Geraldo le os precos das tradings no grupo do WhatsApp
# Uso (no VPS, como root):
#   curl -fsSL https://ericgelati.github.io/gelati-disparos/instalar-geraldo.sh | bash -s -- NUMERO_ERIC[,OUTRO]
# =============================================================================
set -euo pipefail
verde() { printf "\n\033[1;32m==> %s\033[0m\n" "$*"; }
erro()  { printf "\n\033[1;31mERRO: %s\033[0m\n" "$*"; exit 1; }
[ "$(id -u)" -eq 0 ] || erro "rode como root."
NUMEROS="${1:-}"; [ -n "$NUMEROS" ] || erro "informe o numero do Eric (ex.: 5535999155685)"
EVO=/opt/evolution; DIR=/opt/gelati-geraldo
SA=/opt/gelati-drive-whatsapp/service-account.json
[ -f "$EVO/.env" ] || erro "Evolution nao encontrado em $EVO"
[ -f "$SA" ] || erro "service-account.json nao encontrado em $SA"
APIKEY="$(grep '^AUTHENTICATION_API_KEY=' $EVO/.env | cut -d= -f2)"

verde "1/4 Preparando $DIR"
mkdir -p "$DIR/dados"; cd "$DIR"
cp "$SA" sa.json; chmod 600 sa.json
printf "APIKEY=%s\nERIC_NUMEROS=%s\nINSTANCIA=gelati-soja\nTZ=America/Sao_Paulo\n" "$APIKEY" "$NUMEROS" > .env
chmod 600 .env
cat > geraldo.py <<'EOF_GERALDO_PY'
#!/usr/bin/env python3
"""
E. F. GELATI - Geraldo: le os precos de soja que as tradings mandam no grupo
do WhatsApp, pede confirmacao ao Eric no privado e lanca na aba "Precos" da
planilha "Precos Soja - 2027 FINAL".

Fluxo:
  1. Evolution (instancia gelati-soja) manda cada mensagem recebida para
     POST http://gelati-geraldo:8091/webhook
  2. Texto "SOJA SANTOS 2027 / FEV C 30/04 142,00 ..."  -> SOMA
     Imagem "CIF PORTO" (tabela COFCO)                 -> COFCO (OCR)
     Outra imagem/texto com precos                     -> pergunta a trading
  3. Geraldo manda o resumo ao Eric. Respostas aceitas no privado:
       OK            lanca a leitura mais recente
       OK COFCO      lanca na trading informada
       OK 12         lanca a leitura numero 12
       NAO           descarta a leitura mais recente
  4. Primeiro lancamento do dia apaga B3:H15; os seguintes so trocam a linha
     da trading. O robo de disparos le a planilha antes de cada envio.
"""
import base64
import io
import json
import os
import re
import threading
import time
import unicodedata
import urllib.parse
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from zoneinfo import ZoneInfo

import requests
from google.auth.transport.requests import AuthorizedSession
from google.oauth2 import service_account

TZ = ZoneInfo("America/Sao_Paulo")
EVO_URL = os.environ.get("EVO_URL", "http://evolution-api:8080").rstrip("/")
APIKEY = os.environ["APIKEY"]
INSTANCIA = os.environ.get("INSTANCIA", "gelati-soja")
ERIC = [n.strip() for n in os.environ.get("ERIC_NUMEROS", "").split(",") if n.strip()]
SHEET_ID = os.environ.get("SHEET_ID", "1YSseJkC5UMjqI0rsS1W0FHT0CM2wKWJxuP8x_pxJetY")
ABA = os.environ.get("ABA", "Preços")
SA_FILE = os.environ.get("SA_FILE", "/sa.json")
HORA_DISPARO = os.environ.get("HORA_DISPARO", "11:10")
DATA = Path(os.environ.get("DATA_DIR", "/data"))
ESTADO = DATA / "geraldo.json"
LOCK = threading.Lock()

MESES = ["Fev", "Mar", "Abr", "Mai", "Jun"]          # colunas C..G
COLS = ["C", "D", "E", "F", "G"]
MES_ALIAS = {
    "fev": 0, "fevereiro": 0, "mar": 1, "marco": 1, "abr": 2, "abril": 2,
    "mai": 3, "maio": 3, "jun": 4, "junho": 4,
}
TRADINGS = ["3TENTOS", "ADM", "AMAGGI", "BTG", "BUNGE", "CARGILL", "CEREALPHA",
            "CJ", "COFCO", "CUTRALE", "LDC", "OLAM", "SOMA"]


def log(*a):
    print(datetime.now(TZ).strftime("%d/%m %H:%M:%S"), *a, flush=True)


def norm(s):
    s = unicodedata.normalize("NFD", str(s)).encode("ascii", "ignore").decode()
    return re.sub(r"\s+", " ", s).strip().lower()


def ler_estado():
    try:
        return json.loads(ESTADO.read_text(encoding="utf-8"))
    except Exception:
        return {"seq": 0, "pendentes": [], "ultimo_dia": ""}


def gravar_estado(e):
    tmp = ESTADO.with_suffix(".tmp")
    tmp.write_text(json.dumps(e, ensure_ascii=False), encoding="utf-8")
    tmp.replace(ESTADO)


def br(v):
    return f"{v:.2f}".replace(".", ",")


# ------------------------------------------------------------------ leitura
def numero(txt):
    try:
        return float(txt.replace(".", "").replace(",", ".")) if "," in txt else float(txt)
    except ValueError:
        return None


def ler_linhas(texto):
    """Devolve {indice_mes: preco} a partir de linhas 'Fevereiro ... R$ 141,67'."""
    precos = {}
    t = norm(texto)
    achados = [(m.start(), MES_ALIAS[m.group(1)]) for m in
               re.finditer(r"\b(" + "|".join(sorted(MES_ALIAS, key=len, reverse=True)) + r")\b", t)]
    for k, (pos, mi) in enumerate(achados):
        fim = achados[k + 1][0] if k + 1 < len(achados) else len(t)
        trecho = re.sub(r"\d{1,2}/\d{1,2}(/\d{2,4})?", " ", t[pos:fim])
        for n in re.findall(r"\d{2,3}[.,]\d{1,2}", trecho):
            v = numero(n)
            if v is not None and 80 <= v <= 300:     # soja; milho fica de fora
                precos.setdefault(mi, round(v, 2))
                break
    return precos


def ler_imagem(textos):
    """Le cada variante do OCR e fica com o valor mais votado de cada mes."""
    from collections import Counter
    votos = {}
    for t in textos:
        for mi, v in ler_linhas(t).items():
            votos.setdefault(mi, Counter())[v] += 1
    return {mi: c.most_common(1)[0][0] for mi, c in votos.items()}


def trading_no_texto(texto):
    t = norm(texto).upper()
    for nome in TRADINGS:
        if re.search(r"\b" + re.escape(nome) + r"\b", t):
            return nome
    return None


def ocr(imagem_bytes):
    import pytesseract
    from PIL import Image, ImageOps
    base = Image.open(io.BytesIO(imagem_bytes)).convert("L")
    base = base.resize((base.width * 3, base.height * 3), Image.LANCZOS)
    base = ImageOps.autocontrast(base)
    # fundos coloridos somem em algumas variantes; junta o texto de todas
    variantes = [base] + [base.point(lambda p, c=c: 255 if p > c else 0) for c in (110, 150, 190)]
    textos = []
    for v in variantes:
        for psm in ("6", "4"):
            textos.append(pytesseract.image_to_string(v, lang="por", config=f"--psm {psm}"))
    return textos


# ------------------------------------------------------------- Evolution
def evo(metodo, rota, **kw):
    r = requests.request(metodo, f"{EVO_URL}{rota}", headers={"apikey": APIKEY}, timeout=60, **kw)
    r.raise_for_status()
    return r.json() if r.content else {}


def enviar(numero_dest, texto):
    try:
        evo("POST", f"/message/sendText/{INSTANCIA}", json={"number": numero_dest, "text": texto})
    except Exception as e:
        log("falha ao enviar texto:", e)


def avisar_eric(texto):
    if ERIC:
        enviar(ERIC[0], texto)


def baixar_imagem(data):
    b64 = (data.get("message") or {}).get("base64")
    if not b64:
        r = evo("POST", f"/chat/getBase64FromMediaMessage/{INSTANCIA}",
                json={"message": {"key": data["key"]}, "convertToMp4": False})
        b64 = r.get("base64")
    if b64 and "," in b64[:100]:
        b64 = b64.split(",", 1)[1]
    return base64.b64decode(b64) if b64 else None


# ---------------------------------------------------------------- planilha
_sessao = None


def sheets():
    global _sessao
    if _sessao is None:
        cred = service_account.Credentials.from_service_account_file(
            SA_FILE, scopes=["https://www.googleapis.com/auth/spreadsheets"])
        _sessao = AuthorizedSession(cred)
    return _sessao


def faixa(a1):
    return urllib.parse.quote(f"'{ABA}'!{a1}", safe="")


def api(metodo, caminho, **kw):
    url = f"https://sheets.googleapis.com/v4/spreadsheets/{SHEET_ID}{caminho}"
    r = sheets().request(metodo, url, timeout=60, **kw)
    if r.status_code >= 400:
        raise RuntimeError(f"Google Sheets {r.status_code}: {r.text[:300]}")
    return r.json()


def lancar(trading, precos):
    """Grava a linha da trading. Devolve (limpou_dia, melhor_preco)."""
    hoje = datetime.now(TZ).strftime("%Y-%m-%d")
    est = ler_estado()
    limpou = False
    if est.get("ultimo_dia") != hoje:
        api("POST", f"/values/{faixa('B3:H15')}:clear", json={})
        est["ultimo_dia"] = hoje
        gravar_estado(est)
        limpou = True
    nomes = api("GET", f"/values/{faixa('A3:A15')}").get("values", [])
    linha = None
    for i, row in enumerate(nomes):
        if row and norm(row[0]) == norm(trading):
            linha = 3 + i
            break
    if linha is None:
        raise RuntimeError(f"trading {trading} nao encontrada na coluna A da aba {ABA}")
    valores = [precos.get(i, "") for i in range(5)]
    api("PUT", f"/values/{faixa(f'C{linha}:G{linha}')}",
        params={"valueInputOption": "RAW"}, json={"values": [valores]})
    melhor = api("GET", f"/values/{faixa('C16:G16')}",
                 params={"valueRenderOption": "FORMATTED_VALUE"}).get("values", [[]])
    return limpou, (melhor[0] if melhor else [])


# ---------------------------------------------------------------- fluxo
def resumo(precos):
    return " | ".join(f"{MESES[i]} {br(precos[i])}" if i in precos else f"{MESES[i]} —" for i in range(5))


def nova_leitura(trading, precos, origem):
    with LOCK:
        est = ler_estado()
        est["seq"] = est.get("seq", 0) + 1
        n = est["seq"]
        est["pendentes"] = [p for p in est.get("pendentes", []) if p.get("dia") == datetime.now(TZ).strftime("%Y-%m-%d")]
        est["pendentes"].append({"n": n, "trading": trading, "precos": {str(k): v for k, v in precos.items()},
                                 "origem": origem, "dia": datetime.now(TZ).strftime("%Y-%m-%d")})
        gravar_estado(est)
    quem = f"*{trading}*" if trading else "*trading não identificada*"
    msg = (f"🤖 Geraldo leu os preços de {quem} (leitura {n}, {origem}):\n"
           f"{resumo(precos)}\n\n")
    if trading:
        msg += "Responda *OK* para lançar, *OK NOME* para lançar em outra trading ou *NÃO* para descartar."
    else:
        msg += "De qual trading é? Responda *OK NOME* (ex.: OK CARGILL) ou *NÃO* para descartar."
    avisar_eric(msg)
    log("leitura", n, trading, precos, origem)


def resposta_eric(texto):
    t = norm(texto).upper()
    with LOCK:
        est = ler_estado()
        pend = est.get("pendentes", [])
        if not pend:
            return
        if t in ("NAO", "N", "NAO LANCAR", "DESCARTAR"):
            p = pend.pop()
            gravar_estado(est)
            avisar_eric(f"🗑️ Leitura {p['n']} descartada.")
            return
        m = re.match(r"^OK\b\s*(\d+)?\s*([A-Z0-9 ]+)?$", t)
        if not m:
            return
        num, nome = m.group(1), (m.group(2) or "").strip()
        p = next((x for x in pend if str(x["n"]) == num), None) if num else pend[-1]
        if not p:
            avisar_eric(f"Não achei a leitura {num}.")
            return
        trading = nome or p.get("trading")
        if not trading:
            avisar_eric(f"Preciso saber a trading da leitura {p['n']}. Responda OK {p['n']} NOME.")
            return
        if norm(trading).upper() not in TRADINGS:
            avisar_eric(f"Não conheço a trading '{trading}'. Use um destes nomes: {', '.join(TRADINGS)}.")
            return
        pend.remove(p)
        gravar_estado(est)
    precos = {int(k): v for k, v in p["precos"].items()}
    try:
        limpou, melhor = lancar(trading.upper(), precos)
    except Exception as e:
        log("erro ao lancar:", e)
        avisar_eric(f"⚠️ Não consegui lançar na planilha: {e}")
        return
    agora = datetime.now(TZ)
    msg = f"✅ Lançado *{trading.upper()}*: {resumo(precos)}"
    if limpou:
        msg += "\n(primeiro preço do dia: apaguei as referências anteriores)"
    if melhor:
        msg += "\nMelhor preço: " + " | ".join(f"{MESES[i]} {v}" for i, v in enumerate(melhor[:5]))
    if agora.strftime("%H:%M") >= HORA_DISPARO and agora.weekday() < 5:
        msg += (f"\n⏰ O disparo das {HORA_DISPARO} de hoje já saiu. "
                "Se quiser reenviar com estes preços, peça ao Claude.")
    avisar_eric(msg)
    log("lancado", trading, precos)


def eh_eric(jid):
    dig = re.sub(r"\D", "", jid.split("@")[0])
    return any(dig[-8:] == re.sub(r"\D", "", n)[-8:] for n in ERIC)


def processar(evento):
    if evento.get("event") not in ("messages.upsert", "MESSAGES_UPSERT"):
        return
    datas = evento.get("data")
    for data in (datas if isinstance(datas, list) else [datas]):
        if not data:
            continue
        key = data.get("key") or {}
        if key.get("fromMe"):
            continue
        jid = key.get("remoteJid", "")
        msg = data.get("message") or {}
        texto = (msg.get("conversation") or (msg.get("extendedTextMessage") or {}).get("text")
                 or (msg.get("imageMessage") or {}).get("caption") or "")
        de_grupo = jid.endswith("@g.us")
        do_eric = not de_grupo and eh_eric(jid)
        if not de_grupo and not do_eric:
            continue
        origem = "grupo" if de_grupo else "seu privado"

        # resposta de confirmacao do Eric
        if do_eric and texto and re.match(r"^\s*(ok|nao|não|n|descartar)\b", texto, re.I) \
                and not ler_linhas(texto):
            resposta_eric(texto)
            continue

        if "imageMessage" in msg:
            try:
                img = baixar_imagem(data)
                textos = ocr(img) if img else []
            except Exception as e:
                log("falha no OCR:", e)
                continue
            lido = "\n".join(textos)
            precos = ler_imagem(textos)
            if len(precos) < 2:
                continue
            if not re.search(r"SOJA|CIF", norm(lido).upper()):
                continue
            trading = trading_no_texto(texto) or trading_no_texto(lido)
            if not trading and "CIF PORTO" in norm(lido).upper():
                trading = "COFCO"
            nova_leitura(trading, precos, origem)
        elif texto:
            if "SOJA" not in norm(texto).upper():
                continue
            precos = ler_linhas(texto)
            if len(precos) < 2:
                continue
            trading = trading_no_texto(texto)
            if not trading and "SOJA SANTOS" in norm(texto).upper():
                trading = "SOMA"
            nova_leitura(trading, precos, origem)


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b'{"ok":true}')

    def do_POST(self):
        n = int(self.headers.get("Content-Length", "0") or 0)
        corpo = self.rfile.read(n) if n else b"{}"
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"ok")
        try:
            evento = json.loads(corpo.decode("utf-8"))
        except Exception:
            return
        threading.Thread(target=self._seguro, args=(evento,), daemon=True).start()

    @staticmethod
    def _seguro(evento):
        try:
            processar(evento)
        except Exception as e:
            log("erro:", e)


if __name__ == "__main__":
    DATA.mkdir(parents=True, exist_ok=True)
    log("Geraldo ouvindo na porta 8091 | instancia", INSTANCIA, "| Eric", ERIC)
    ThreadingHTTPServer(("0.0.0.0", 8091), H).serve_forever()
EOF_GERALDO_PY

cat > Dockerfile <<'EOF_DOCKER'
FROM python:3.12-slim
RUN apt-get update && apt-get install -y --no-install-recommends tesseract-ocr tesseract-ocr-por \
    && rm -rf /var/lib/apt/lists/*
RUN pip install --no-cache-dir requests google-auth pillow pytesseract
COPY geraldo.py /app/geraldo.py
ENV PYTHONUNBUFFERED=1 DATA_DIR=/data SA_FILE=/sa.json
CMD ["python", "/app/geraldo.py"]
EOF_DOCKER

cat > docker-compose.yml <<'EOF_COMPOSE'
services:
  gelati-geraldo:
    build: .
    container_name: gelati_geraldo
    restart: always
    env_file: .env
    volumes:
      - ./dados:/data
      - ./sa.json:/sa.json:ro
networks:
  default:
    name: evolution_default
    external: true
EOF_COMPOSE

verde "2/4 Construindo o Geraldo (leva 2-4 minutos na primeira vez)"
docker compose up -d --build
sleep 5
docker logs --tail 3 gelati_geraldo

verde "3/4 Ligando o webhook da instancia gelati-soja"
curl -fsS -X POST "http://localhost:8080/webhook/set/gelati-soja" \
  -H "apikey: $APIKEY" -H "Content-Type: application/json" \
  -d '{"webhook":{"enabled":true,"url":"http://gelati-geraldo:8091/webhook","byEvents":false,"base64":true,"events":["MESSAGES_UPSERT"]}}' \
  && echo "" && echo "    webhook ligado" || echo "    AVISO: nao consegui ligar o webhook"

verde "4/4 Conferindo"
docker exec gelati_geraldo python -c "import urllib.request;print(urllib.request.urlopen('http://localhost:8091').read())"
printf "\n\033[1;32m================ PRONTO ================\033[0m\n"
echo "Logs do Geraldo: docker logs -f gelati_geraldo"
