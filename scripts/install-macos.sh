#!/bin/sh
# Instala o DeckOS como agente do launchd do usuario (abre no login, reinicia se cair).
# Pode rodar de novo quantas vezes quiser: atualiza a copia e recarrega o agente.
#
#   ./install-macos.sh [pasta-do-DeckOS]   # a pasta descompactada do release (padrao: a deste script ou a atual)
#   ./install-macos.sh --uninstall
set -eu

LABEL="io.github.itskavin.deckos"
APP_DIR="$HOME/Library/Application Support/DeckOS/app"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG_DIR="$HOME/Library/Logs/DeckOS"
DOMAIN="gui/$(id -u)"

unload() {
  launchctl bootout "$DOMAIN/$LABEL" >/dev/null 2>&1 || true
}

if [ "${1:-}" = "--uninstall" ]; then
  unload
  rm -f "$PLIST"
  rm -rf "$APP_DIR"
  echo "DeckOS removido. Perfis e chave continuam em ~/Library/Application Support/DeckOS."
  exit 0
fi

# Onde esta o executavel publicado (DeckOS + wwwroot/).
SRC="${1:-}"
if [ -z "$SRC" ]; then
  for d in "$(cd "$(dirname "$0")" && pwd)" "$(pwd)"; do
    if [ -x "$d/DeckOS" ]; then SRC="$d"; break; fi
  done
fi
if [ -z "$SRC" ] || [ ! -f "$SRC/DeckOS" ]; then
  echo "Não achei o executável DeckOS. Passe a pasta do release: $0 /caminho/DeckOS-macos" >&2
  exit 1
fi
SRC="$(cd "$SRC" && pwd)"

unload
if [ "$SRC" != "$APP_DIR" ]; then
  mkdir -p "$APP_DIR"
  # Copia limpa: sobras de uma versao antiga nao ficam misturadas com a nova.
  rm -rf "$APP_DIR"
  mkdir -p "$APP_DIR"
  cp -R "$SRC"/. "$APP_DIR"/
fi
chmod +x "$APP_DIR/DeckOS"
# Baixado pelo navegador: sem isto o Gatekeeper recusa o binario sem assinatura.
xattr -dr com.apple.quarantine "$APP_DIR" 2>/dev/null || true

mkdir -p "$LOG_DIR" "$(dirname "$PLIST")"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$APP_DIR/DeckOS</string>
    <string>--headless</string>
  </array>
  <key>WorkingDirectory</key><string>$APP_DIR</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ProcessType</key><string>Interactive</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
  <key>StandardOutPath</key><string>$LOG_DIR/deckos.log</string>
  <key>StandardErrorPath</key><string>$LOG_DIR/deckos.log</string>
</dict>
</plist>
EOF

launchctl bootstrap "$DOMAIN" "$PLIST"
launchctl enable "$DOMAIN/$LABEL" >/dev/null 2>&1 || true

echo "DeckOS instalado e rodando (abre sozinho no login)."
echo "  Configurador: http://localhost:4787/"
echo "  QR de pareamento e log: $LOG_DIR/deckos.log"
echo
echo "Para teclas, atalhos e travar a tela, libere o DeckOS em"
echo "  Ajustes do Sistema > Privacidade e Segurança > Acessibilidade"
echo "  (o macOS pergunta no primeiro atalho; o binário é $APP_DIR/DeckOS)."
