#!/usr/bin/env bats

load helpers/load

@test "last-good rescue and rollback restore a blessable writable root" {
  run "$QEMU_HARNESS" rollback

  [ "$status" -eq 0 ]
  assert_scenario_result rollback '
    .last_good_selected == true and
    .latest_resolved_to_pinned_pre == true and
    .default_subvolume_transitioned == true and
    .active_equals_default == true and
    .blessed == true and
    .seed_retired == true and
    .post_snapper_power_loss.valid_state == true and
    .post_snapper_power_loss.two_valid_ukis == true
  '
}
