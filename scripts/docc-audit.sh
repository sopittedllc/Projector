#!/bin/bash
# DocC Coverage Audit Script
# Scans Swift files for public/internal APIs and counts DocC comments

echo "=== DocC Coverage Audit ==="
echo ""

# Function to calculate coverage for a file
audit_file() {
    local file="$1"

    # Count public/internal APIs (functions, classes, structs, enums, properties)
    local total_apis=$(grep -E "^\s*(public|internal)\s+(func|class|struct|enum|actor|protocol|var|let)" "$file" | wc -l | tr -d ' ')

    # Count DocC comments (lines starting with ///)
    local docc_comments=$(grep -c "^\s*///" "$file" || echo 0)

    if [ "$total_apis" -gt 0 ]; then
        local percent=$((docc_comments * 100 / total_apis))
        printf "%-60s %3d/%3d APIs (%3d%%)\n" "$file" "$docc_comments" "$total_apis" "$percent"
    fi
}

# Managers (high priority)
echo "📁 Managers/"
echo "───────────────────────────────────────────────────────────────────"
for file in Projector/Managers/*.swift; do
    [ -f "$file" ] && audit_file "$file"
done
echo ""

# Contracts (should be 100%)
echo "📁 Contracts/"
echo "───────────────────────────────────────────────────────────────────"
for file in Projector/Contracts/*.swift; do
    [ -f "$file" ] && audit_file "$file"
done
echo ""

# ViewModels
echo "📁 ViewModels/"
echo "───────────────────────────────────────────────────────────────────"
for file in Projector/ViewModels/*.swift; do
    [ -f "$file" ] && audit_file "$file"
done
echo ""

# Models
echo "📁 Models/"
echo "───────────────────────────────────────────────────────────────────"
for file in Projector/Models/*.swift; do
    [ -f "$file" ] && audit_file "$file"
done
echo ""

# Views (critical ones only)
echo "📁 Views/ (Critical)"
echo "───────────────────────────────────────────────────────────────────"
for file in Projector/Views/ContentView.swift \
            Projector/Views/VitalControlsBar.swift \
            Projector/Views/Timeline/*.swift; do
    [ -f "$file" ] && audit_file "$file"
done
echo ""

# Find files with <50% coverage
echo "⚠️  Files with <50% DocC coverage:"
echo "───────────────────────────────────────────────────────────────────"

find Projector -name "*.swift" -type f | while read -r file; do
    total_apis=$(grep -E "^\s*(public|internal)\s+(func|class|struct|enum|actor|protocol|var|let)" "$file" | wc -l | tr -d ' ')
    docc_comments=$(grep -c "^\s*///" "$file" || echo 0)

    if [ "$total_apis" -gt 0 ]; then
        percent=$((docc_comments * 100 / total_apis))
        if [ "$percent" -lt 50 ]; then
            printf "%-60s %3d%%\n" "$file" "$percent"
        fi
    fi
done

echo ""
echo "✅ Audit complete. Target: 100% coverage on all public APIs."
