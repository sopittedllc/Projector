#!/bin/bash
# DocC Coverage Audit Script
# Scans Swift files for public/internal APIs and counts DocC comments

echo "=== DocC Coverage Audit ==="
echo ""

# Print "documented total". A declaration is documented only when a DocC
# block immediately precedes it (attributes between the block and declaration
# are allowed). Counting comment *lines* made the old script report 5,500%.
coverage_counts() {
    awk '
        /^[[:space:]]*\/\/\// { has_docc = 1; next }
        /^[[:space:]]*@[A-Za-z]/ { next }
        /^[[:space:]]*public[[:space:]]+(final[[:space:]]+)?(func|class|struct|enum|actor|protocol|var|let)[[:space:]]/ {
            total++
            if (has_docc) documented++
            has_docc = 0
            next
        }
        /^[[:space:]]*$/ { next }
        { has_docc = 0 }
        END { print documented + 0, total + 0 }
    ' "$1"
}

audit_file() {
    local file="$1"
    local documented total
    read -r documented total < <(coverage_counts "$file")

    if [ "$total" -gt 0 ]; then
        local percent=$((documented * 100 / total))
        printf "%-60s %3d/%3d APIs (%3d%%)\n" "$file" "$documented" "$total" "$percent"
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
    read -r docc_comments total_apis < <(coverage_counts "$file")

    if [ "$total_apis" -gt 0 ]; then
        percent=$((docc_comments * 100 / total_apis))
        if [ "$percent" -lt 50 ]; then
            printf "%-60s %3d%%\n" "$file" "$percent"
        fi
    fi
done

echo ""
echo "✅ Audit complete. Target: 100% coverage on all public APIs."
