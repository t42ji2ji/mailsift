#!/bin/zsh
# Regenerates favicons and og-image.png from assets/icon.png.
#   ./make-images.sh            use the existing assets/icon.png
#   ./make-images.sh --placeholder   first write a placeholder icon (black rounded square, white "M")
# Needs ImageMagick 7 (magick).
set -euo pipefail
cd "${0:A:h}"

BOLD="/System/Library/Fonts/Supplemental/Arial Bold.ttf"
REG="/System/Library/Fonts/Supplemental/Arial.ttf"
PAPER="#ececea"; INK="#161616"; MUTED="#6b6b6b"

if [[ "${1:-}" == "--placeholder" || ! -f assets/icon.png ]]; then
  magick -size 1024x1024 xc:none \
    -fill "$INK" -draw "roundrectangle 100,100 923,923 185,185" \
    -font "$BOLD" -pointsize 560 -fill white -gravity center -annotate +0+20 "M" \
    assets/icon.png
fi

magick assets/icon.png -resize 32x32 favicon-32.png
magick assets/icon.png -resize 192x192 favicon-192.png
magick assets/icon.png -resize 180x180 apple-touch-icon.png

# 1200×630: icon on the left, name and tagline on the right, paper background
magick -size 1200x630 "xc:$PAPER" \
  \( assets/icon.png -resize 300x300 \) -gravity west -geometry +96+0 -composite \
  -gravity northwest \
  -font "$BOLD" -pointsize 104 -fill "$INK" -annotate +440+200 "MailSift" \
  -font "$REG" -pointsize 38 -fill "$MUTED" -annotate +446+340 "Search Apple Mail by meaning." \
  -font "$REG" -pointsize 38 -fill "$MUTED" -annotate +446+392 "On your Mac. Free and open source." \
  -fill "#D64A29" -draw "rectangle 446,470 506,476" \
  og-image.png

chmod 644 assets/icon.png favicon-32.png favicon-192.png apple-touch-icon.png og-image.png
echo "wrote favicon-32.png favicon-192.png apple-touch-icon.png og-image.png"
