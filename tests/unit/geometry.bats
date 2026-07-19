#!/usr/bin/env bats

load ../helpers/load

setup() {
  load_lib geometry
}

@test "allocates an aligned 2 GiB ESP and reserves the GPT tail" {
  run partition_geometry_json 2000398934016 512

  [ "$status" -eq 0 ]
  jq -e '
    .esp.start_bytes == 1048576 and
    .esp.size_bytes == 2147483648 and
    .root.start_bytes == 2148532224 and
    .root.size_bytes == 1998249263104 and
    (.root.start_bytes % 1048576) == 0 and
    (.root.size_bytes % 1048576) == 0 and
    (.root.start_bytes + .root.size_bytes) <= (2000398934016 - 1048576)
  ' <<<"$output"
}

@test "rejects sector sizes that cannot express MiB alignment" {
  run partition_geometry_json 2000398934016 1000
  [ "$status" -ne 0 ]
}

@test "rejects undersized and non-integer disks" {
  run partition_geometry_json 34359738368 512
  [ "$status" -ne 0 ]
  run partition_geometry_json 2TB 512
  [ "$status" -ne 0 ]
}
