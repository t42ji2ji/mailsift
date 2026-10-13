#!/bin/zsh
# Regenerates favicons and og-image.png from assets/icon.png.
#   ./make-images.sh            use the existing assets/icon.png
#   ./make-images.sh --placeholder   first write a placeholder icon (black rounded square, white "M")
# Needs ImageMagick 7 (magick).
set -euo pipefail
cd "${0:A:h}"

BOLD="/System/Library/Fonts/Supplemental/Arial Bold.ttf"
INK="#000000"

if [[ "${1:-}" == "--placeholder" || ! -f assets/icon.png ]]; then
  magick -size 1024x1024 xc:none \
    -fill "$INK" -draw "roundrectangle 100,100 923,923 185,185" \
    -font "$BOLD" -pointsize 560 -fill white -gravity center -annotate +0+20 "M" \
    assets/icon.png
fi

magick assets/icon.png -resize 32x32 favicon-32.png
magick assets/icon.png -resize 192x192 favicon-192.png
magick assets/icon.png -resize 180x180 apple-touch-icon.png

# 1200×630 in the app's look: canvas gray, ink wordmark, muted tagline, the icon on the right
SF="/System/Library/Fonts/SFNS.ttf"
magick -size 1200x630 "xc:#f6f6f6" \
  -fill "#000000" -draw "roundrectangle 96,214 136,254 10,10" \
  -font "$SF" -pointsize 92 -fill "#000000" -stroke "#000000" -strokewidth 3 -gravity northwest -annotate +160+196 "MailSift" \
  -font "$SF" -stroke none -pointsize 40 -fill "#858585" -annotate +98+330 "Find any email by describing it." \
  -font "$SF" -pointsize 26 -fill "#a3a3a3" -annotate +98+520 "macOS · free and open source" \
  \( assets/icon.png -resize 280x280 \) -gravity east -geometry +110+0 -composite \
  og-image.png

chmod 644 assets/icon.png favicon-32.png favicon-192.png apple-touch-icon.png og-image.png
echo "wrote favicon-32.png favicon-192.png apple-touch-icon.png og-image.png"
