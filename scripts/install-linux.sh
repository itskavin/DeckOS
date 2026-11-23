#!/bin/sh
# Instala o DeckOS como servico do systemd do usuario (abre no login, reinicia se cair).
# Pode rodar de novo quantas vezes quiser: atualiza a copia e reinicia o servico.
#
#   ./install-linux.sh [pasta-do-DeckOS]   # a pasta descompactada do release (padrao: a deste script ou a atual)
#   ./install-linux.sh --uninstall
set -eu

UNIT="deckos.service"
DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
APP_DIR="$DATA_HOME/deckos/app"
UNIT_DIR="$CONFIG_HOME/systemd/user"

if ! command -v systemctl >/dev/null 2>&1; then
  echo "Sem systemd: rode o DeckOS direto ($APP_DIR/DeckOS) pelo autostart da sua sessão." >&2
  exit 1
fi

if [ "${1:-}" = "--uninstall" ]; then
  systemctl --user disable --now "$UNIT" >/dev/null 2>&1 || true
  rm -f "$UNIT_DIR/$UNIT"
  systemctl --user daemon-reload
  rm -rf "$APP_DIR"
  echo "DeckOS removido. Perfis e chave continuam em $CONFIG_HOME/deckos."
  exit 0
fi

SRC="${1:-}"
if [ -z "$SRC" ]; then
  for d in "$(cd "$(dirname "$0")" && pwd)" "$(pwd)"; do
    if [ -f "$d/DeckOS" ]; then SRC="$d"; break; fi
  done
fi
if [ -z "$SRC" ] || [ ! -f "$SRC/DeckOS" ]; then
  echo "Não achei o executável DeckOS. Passe a pasta do release: $0 /caminho/DeckOS-linux" >&2
  exit 1
fi
SRC="$(cd "$SRC" && pwd)"

systemctl --user stop "$UNIT" >/dev/null 2>&1 || true
if [ "$SRC" != "$APP_DIR" ]; then
  # Copia limpa: sobras de uma versao antiga nao ficam misturadas com a nova.
  rm -rf "$APP_DIR"
  mkdir -p "$APP_DIR"
  cp -R "$SRC"/. "$APP_DIR"/
fi
chmod +x "$APP_DIR/DeckOS"

# Com sessao grafica, sobe junto com ela (as ferramentas de teclado precisam do DISPLAY /
# WAYLAND_DISPLAY que a sessao exporta para o systemd); sem, no login.
TARGET="default.target"
if systemctl --user list-unit-files graphical-session.target >/dev/null 2>&1 &&
   systemctl --user list-unit-files graphical-session.target | grep -q graphical-session; then
  TARGET="graphical-session.target"
fi

mkdir -p "$UNIT_DIR"
cat > "$UNIT_DIR/$UNIT" <<EOF
[Unit]
Description=DeckOS (servidor do Stream Deck no celular)
After=network-online.target $TARGET
PartOf=$TARGET

[Service]
Type=simple
WorkingDirectory=$APP_DIR
ExecStart=$APP_DIR/DeckOS --headless
Restart=on-failure
RestartSec=3
Environment=DOTNET_CLI_TELEMETRY_OPTOUT=1

[Install]
WantedBy=$TARGET
EOF

systemctl --user daemon-reload
systemctl --user enable "$UNIT" >/dev/null
systemctl --user restart "$UNIT"

echo "DeckOS instalado e rodando (abre sozinho no login)."
echo "  Configurador: http://localhost:4787/"
echo "  QR de pareamento e log: journalctl --user -u deckos -f"
echo
echo "Pacotes opcionais (o configurador mostra o que falta em cada recurso):"
echo "  teclas X11: xdotool · Wayland: ydotool (com ydotoold) ou wtype"
echo "  volume: wireplumber (wpctl) ou pulseaudio-utils (pactl) · mídia: playerctl"
echo "  janelas/perfil automático (X11): xdotool, wmctrl · sons: mpv ou ffmpeg · USB: adb"
