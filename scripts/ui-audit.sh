#!/bin/bash
#
# UI Design System Audit Script
# Finds hardcoded spacing, padding, and styling violations
# that should use LayoutConstants.swift or LiquidGlassStyles.swift
#
# Usage: ./scripts/ui-audit.sh
#

set -e

VIEWS_DIR="Projector/Views"
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cd "$PROJECT_ROOT"

echo "=========================================="
echo "  UI Design System Audit"
echo "=========================================="
echo ""

# Color output
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

violation_count=0

# ==========================================
# 1. Hardcoded Spacing/Padding Violations
# ==========================================

echo -e "${BLUE}=== 1. Hardcoded Spacing Violations ===${NC}"
echo "Looking for .padding(NUMBER) without Spacing.* constants..."
echo ""

while IFS= read -r match; do
    ((violation_count++))
    echo -e "${RED}VIOLATION:${NC} $match"
done < <(grep -rn "\.padding([0-9]\+)" "$VIEWS_DIR" 2>/dev/null | \
    grep -v "Spacing\." | \
    grep -v "LayoutConstants" | \
    grep -v "//.*\.padding" || true)

echo ""
while IFS= read -r match; do
    ((violation_count++))
    echo -e "${RED}VIOLATION:${NC} $match"
done < <(grep -rn "VStack(spacing: [0-9]\+)" "$VIEWS_DIR" 2>/dev/null | \
    grep -v "Spacing\." || true)

echo ""
while IFS= read -r match; do
    ((violation_count++))
    echo -e "${RED}VIOLATION:${NC} $match"
done < <(grep -rn "HStack(spacing: [0-9]\+)" "$VIEWS_DIR" 2>/dev/null | \
    grep -v "Spacing\." || true)

echo ""

# ==========================================
# 2. Hardcoded Frame Heights
# ==========================================

echo -e "${BLUE}=== 2. Hardcoded Frame Heights ===${NC}"
echo "Looking for .frame(height: NUMBER) without Layout.* constants..."
echo ""

while IFS= read -r match; do
    ((violation_count++))
    echo -e "${RED}VIOLATION:${NC} $match"
done < <(grep -rn "\.frame(height: [0-9]\+)" "$VIEWS_DIR" 2>/dev/null | \
    grep -v "Layout\." | \
    grep -v "//.*\.frame" || true)

echo ""

# ==========================================
# 3. Non-Standard Button Styles
# ==========================================

echo -e "${BLUE}=== 3. Non-Standard Button Styles ===${NC}"
echo "Looking for buttons with custom padding instead of GlassButtonStyle..."
echo ""

while IFS= read -r match; do
    # Check if the line has GlassButtonStyle
    if ! echo "$match" | grep -q "GlassButtonStyle\|GlassTransportButtonStyle\|GlassActionButtonStyle"; then
        ((violation_count++))
        echo -e "${YELLOW}WARNING:${NC} $match"
    fi
done < <(grep -rn "Button.*{" "$VIEWS_DIR" -A 3 2>/dev/null | \
    grep "\.padding\|\.background" | \
    grep -v "buttonStyle" || true)

echo ""

# ==========================================
# 4. Hardcoded Colors
# ==========================================

echo -e "${BLUE}=== 4. Hardcoded Colors (should use semantic colors) ===${NC}"
echo "Looking for hardcoded RGB/opacity values..."
echo ""

while IFS= read -r match; do
    ((violation_count++))
    echo -e "${YELLOW}WARNING:${NC} $match"
done < <(grep -rn "Color\.blue\.opacity\|Color\.green\.opacity\|Color(red:.*green:.*blue:" "$VIEWS_DIR" 2>/dev/null | \
    grep -v "// OK:" || true)

echo ""

# ==========================================
# 5. Panel Headers Without Standard Heights
# ==========================================

echo -e "${BLUE}=== 5. Panel Headers Without PanelLayout.headerHeight ===${NC}"
echo "Looking for panel-like headers with hardcoded heights..."
echo ""

while IFS= read -r match; do
    if ! echo "$match" | grep -q "PanelLayout\.headerHeight"; then
        ((violation_count++))
        echo -e "${RED}VIOLATION:${NC} $match"
    fi
done < <(grep -rn "// Header\|// Panel Header" "$VIEWS_DIR" -A 5 2>/dev/null | \
    grep "\.frame(height:" || true)

echo ""

# ==========================================
# 6. Missing Glass Modifiers
# ==========================================

echo -e "${BLUE}=== 6. Panels Without .glassPanel() Modifier ===${NC}"
echo "Looking for VStack/ZStack that look like panels but don't use .glassPanel()..."
echo ""

# This is a heuristic check - look for VStack with background that isn't using glassPanel
while IFS= read -r match; do
    file=$(echo "$match" | cut -d':' -f1)
    line=$(echo "$match" | cut -d':' -f2)

    # Check next 5 lines for .glassPanel()
    context=$(sed -n "${line},$((line+5))p" "$file")

    if echo "$context" | grep -q "\.background" && ! echo "$context" | grep -q "\.glassPanel"; then
        ((violation_count++))
        echo -e "${YELLOW}WARNING:${NC} $match (has .background but no .glassPanel)"
    fi
done < <(grep -rn "VStack.*{" "$VIEWS_DIR" 2>/dev/null | \
    head -20 || true)  # Limit to avoid spam

echo ""

# ==========================================
# 7. Hardcoded Font Sizes
# ==========================================

echo -e "${BLUE}=== 7. Hardcoded Font Sizes ===${NC}"
echo "Looking for .font(.system(size: N)) without Typography.* constants..."
echo ""

font_hits=$(grep -rn "\.font(\.system(size: [0-9]" "$VIEWS_DIR" 2>/dev/null | wc -l | tr -d ' ')
if [ "$font_hits" -gt 0 ]; then
    ((violation_count += font_hits))
    echo -e "${YELLOW}WARNING:${NC} $font_hits hardcoded font size(s)"
    grep -rn "\.font(\.system(size: [0-9]" "$VIEWS_DIR" 2>/dev/null | head -15 || true
    if [ "$font_hits" -gt 15 ]; then
        echo "  ... and $((font_hits - 15)) more"
    fi
fi

echo ""

# ==========================================
# 8. Accessibility: Icon-Only Buttons
# ==========================================

echo -e "${BLUE}=== 8. Icon-Only Buttons Without Tooltips ===${NC}"
echo "Comparing .help() coverage against interactive controls per file..."
echo ""

while IFS= read -r file; do
    # grep -c prints 0 and exits 1 when there are no matches, so `|| echo 0`
    # would emit a second line and break the numeric comparison below.
    buttons=$(grep -c "Button(\|Toggle(\|Menu {" "$file" 2>/dev/null || true)
    helps=$(grep -c "\.help(" "$file" 2>/dev/null || true)
    labels=$(grep -c "accessibilityLabel" "$file" 2>/dev/null || true)

    # Only flag files with a meaningful number of controls and no coverage at all
    if [ "$buttons" -ge 4 ] && [ "$helps" -eq 0 ] && [ "$labels" -eq 0 ]; then
        ((violation_count++))
        echo -e "${YELLOW}WARNING:${NC} $(basename "$file") - $buttons controls, no .help() or accessibilityLabel"
    fi
done < <(find "$VIEWS_DIR" -name "*.swift" 2>/dev/null || true)

echo ""

# ==========================================
# Summary
# ==========================================

echo "=========================================="
echo -e "${BLUE}AUDIT SUMMARY${NC}"
echo "=========================================="
echo ""

if [ $violation_count -eq 0 ]; then
    echo -e "${GREEN}✓ No violations found! Design system is consistently applied.${NC}"
    exit 0
else
    echo -e "${RED}✗ Found approximately $violation_count violations${NC}"
    echo ""
    echo "Action items:"
    echo "  1. Review violations above"
    echo "  2. Replace hardcoded values with:"
    echo "     - Spacing.xs, .sm, .md, .lg, .xl, .xxl (for padding/spacing)"
    echo "     - PanelLayout.headerHeight, .footerHeight (for panels)"
    echo "     - TimelineLayout.* (for timeline elements)"
    echo "     - .glassPanel(), .glassControl() (for backgrounds)"
    echo "     - GlassButtonStyle, GlassActionButtonStyle, GlassTransportButtonStyle (for buttons)"
    echo ""
    echo "Target: <10 violations for production readiness"
    exit 1
fi
