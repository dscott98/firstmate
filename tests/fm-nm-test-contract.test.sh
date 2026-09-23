#!/usr/bin/env bash
# Contract: parsed .no-mistakes.yaml must leave commands.test absent or empty,
# and must not carry model or review-loop profiles that no-mistakes honors only
# from the machine-global config (docs/configuration.md "Validation model
# routing"); a repo-side pin would be silently ignored, not an error.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

NM="$ROOT/.no-mistakes.yaml"

test_nm_has_no_deterministic_test_command() {
  command -v ruby >/dev/null 2>&1 \
    || fail "ruby is required to parse .no-mistakes.yaml for this contract"
  local val
  val=$(ruby -ryaml -e '
doc = YAML.load_file(ARGV[0]) || {}
cmds = doc["commands"] || {}
val = cmds.is_a?(Hash) ? cmds["test"] : nil
puts (val.nil? || val == false || val == "") ? "" : val.inspect
' "$NM") || fail "failed to parse .no-mistakes.yaml as YAML"
  if [ -n "$val" ]; then
    fail "commands.test must be absent or empty so Test stays intent-targeted; got: $val"
  fi
  pass "no-mistakes does not configure commands.test"
}

test_nm_has_no_model_or_review_agent_profiles() {
  command -v ruby >/dev/null 2>&1 \
    || fail "ruby is required to parse .no-mistakes.yaml for this contract"
  local extra
  extra=$(ruby -ryaml -e '
doc = YAML.load_file(ARGV[0]) || {}
extra = ["agent_config", "review_agents"].select { |k| doc.key?(k) }
puts extra.join(",")
' "$NM") || fail "failed to parse .no-mistakes.yaml as YAML"
  if [ -n "$extra" ]; then
    fail "no-mistakes honors agent_config and review_agents only from the machine-global config; repo-side keys would be silently ignored, got: $extra"
  fi
  pass "no-mistakes repo config carries no model or review-loop profiles"
}

test_nm_has_no_deterministic_test_command
test_nm_has_no_model_or_review_agent_profiles
