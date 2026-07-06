#!/bin/bash
# Structural checks: manifests parse, hooks.json points at real executable scripts,
# agents and skills have the frontmatter the harness needs.
set -u
here=$(cd "$(dirname "$0")" && pwd)
. "$here/helpers.sh"
root=$(cd "$here/.." && pwd)

for f in .claude-plugin/plugin.json .claude-plugin/marketplace.json hooks/hooks.json; do
  if jq -e . "$root/$f" >/dev/null 2>&1; then _ok "$f parses"; else _bad "$f parses" "valid JSON" "parse error"; fi
done

assert_eq "plugin name matches marketplace entry" \
  "$(jq -r '.name' "$root/.claude-plugin/plugin.json")" \
  "$(jq -r '.plugins[0].name' "$root/.claude-plugin/marketplace.json")"

# Every hook command must resolve to an executable file in the repo.
while IFS= read -r cmd; do
  rel=$(printf '%s' "$cmd" | sed -e 's/^"//' -e 's/".*$//' -e 's|\${CLAUDE_PLUGIN_ROOT}/||')
  if [ -x "$root/$rel" ]; then
    _ok "hook script exists and is executable: $rel"
  else
    _bad "hook script exists and is executable: $rel" "executable file" "missing or not chmod +x"
  fi
done < <(jq -r '.. | .command? // empty' "$root/hooks/hooks.json")

# Agents and skills need name + description frontmatter to register.
for f in "$root"/agents/*.md "$root"/skills/*/SKILL.md; do
  rel=${f#"$root"/}
  if head -20 "$f" | grep -q '^name:' && head -20 "$f" | grep -q '^description:'; then
    _ok "$rel has name+description frontmatter"
  else
    _bad "$rel has name+description frontmatter" "name: and description:" "missing"
  fi
done

# Full harness validation when the claude CLI is around; skipped cleanly otherwise.
if command -v claude >/dev/null 2>&1; then
  if claude plugin validate "$root" >/dev/null 2>&1; then
    _ok "claude plugin validate passes"
  else
    _bad "claude plugin validate passes" "exit 0" "nonzero (run: claude plugin validate $root)"
  fi
else
  echo "  skip  claude CLI not on PATH; skipping harness validation"
fi

finish
