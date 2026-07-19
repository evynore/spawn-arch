#!/usr/bin/env bats

load ../helpers/load.bash

@test "help exposes the approved live installer commands" {
  run "$REPO_ROOT/spawn-arch" --help

  [ "$status" -eq 0 ]
  [[ "$output" == *"doctor"* ]]
  [[ "$output" == *"plan"* ]]
  [[ "$output" == *"install"* ]]
  [[ "$output" == *"verify"* ]]
  [[ "$output" == *"investigate"* ]]
  [[ "$output" != *"gaming"* ]]
}

@test "investigate rejects positional arguments" {
  run "$REPO_ROOT/spawn-arch" investigate extra

  [ "$status" -eq 64 ]
  [[ "$output" == *"investigate accepts no arguments"* ]]
}

@test "unknown command fails with an EX_USAGE status" {
  run "$REPO_ROOT/spawn-arch" explode

  [ "$status" -eq 64 ]
  [[ "$output" == *"unknown command: explode"* ]]
}
