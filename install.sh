#!/bin/bash

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m' # No Color

echo -e "${BLUE}==>${NC} ${BOLD}Installing VoiceScribe...${NC}"

# Check for package_app.sh presence
if [ ! -f "package_app.sh" ]; then
    echo -e "${RED}Error: package_app.sh not found in current directory.${NC}"
    exit 1
fi

echo -e "${BLUE}==>${NC} Running build script..."
./package_app.sh > /dev/null 2>&1

if [ $? -ne 0 ]; then
     ./package_app.sh # Run again to show errors
     echo -e "${RED}Build failed.${NC}"
     exit 1
fi

echo -e "${BLUE}==>${NC} Moving App to /Applications..."

# Remove existing app if present
if [ -d "/Applications/VoiceScribe.app" ]; then
    rm -rf "/Applications/VoiceScribe.app"
fi

# Move the new app
mv "VoiceScribe.app" "/Applications/"

echo -e "${BLUE}==>${NC} Verifying signature..."
codesign --verify "/Applications/VoiceScribe.app"
if [ $? -eq 0 ]; then
    echo -e "   Signature valid."
else
    echo -e "   ⚠️ Signature warning (running locallly is fine)."
fi

echo -e "🍺  ${GREEN}/Applications/VoiceScribe.app was successfully installed!${NC}"
echo -e "    You can now find it in Launchpad or Spotlight."
