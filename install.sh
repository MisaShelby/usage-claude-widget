#!/bin/sh
# Installe (ou met à jour) l'extension « Budget Claude » et l'active.
# Sous Wayland, GNOME ne la charge qu'à la prochaine ouverture de session.
set -e
UUID=claude-budget@misashelby
SRC="$(cd "$(dirname "$0")" && pwd)/$UUID"
DEST="${XDG_DATA_HOME:-$HOME/.local/share}/gnome-shell/extensions/$UUID"

mkdir -p "$DEST"
cp "$SRC"/*.js "$SRC/metadata.json" "$SRC/stylesheet.css" "$DEST/"
echo "Copiée dans $DEST"

CUR=$(gsettings get org.gnome.shell enabled-extensions)
case "$CUR" in
    *"'$UUID'"*) echo "Déjà activée." ;;
    *)
        NEW=$(printf '%s' "$CUR" | sed "s/]\$/, '$UUID']/; s/\[, /[/")
        gsettings set org.gnome.shell enabled-extensions "$NEW"
        echo "Activée."
        ;;
esac
echo "Fermez puis rouvrez votre session pour voir le widget dans la barre du haut."
