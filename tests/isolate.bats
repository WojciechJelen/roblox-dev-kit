#!/usr/bin/env bats

load helpers

@test "isolated environments: lifecycle, parallel ownership and review invariants" {
  setup_fake_machine
  run python3 "$KIT_ROOT/tests/test_isolate.py"
  if [ "$status" -ne 0 ]; then printf '%s\n' "$output" >&2; fi
  [ "$status" -eq 0 ]
}
