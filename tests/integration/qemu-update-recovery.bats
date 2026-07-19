#!/usr/bin/env bats

load helpers/load

@test "boot-critical updates remain recoverable and require blessing" {
  run "$QEMU_HARNESS" update-recovery

  [ "$status" -eq 0 ]
  assert_scenario_result update-recovery '
    .hook_order == ["05-snap-pac-pre", "06-spawn-arch-preserve-uki"] and
    (.pinned_pre_snapshot_id | type == "number" and . > 0) and
    (.last_good_sha256 | test("^[0-9a-f]{64}$")) and
    .second_transaction_blocked == true and
    .non_gpu_checks_passed == true and
    .blessed == true and
    .next_transaction_allowed == true and
    (.power_loss_windows | keys | sort) == [
      "current_candidate", "last_good_temp", "state_temp"
    ] and
    ([.power_loss_windows[] |
      (.valid_state or .valid_previous) and .at_least_one_valid_uki] | all)
  '
}
