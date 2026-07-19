#!/usr/bin/env bash

snapshots_read_raw() {
  local snapshots

  snapshots="$(snapper -c root --jsonout list \
    --columns number,default,active,date,user,cleanup,description,userdata,read-only,pre-number,post-number)" || return $?
  jq -e '
    type == "object" and (.root | type == "array") and
    all(.root[];
      (.number | type == "number" and floor == . and . >= 0) and
      (.["read-only"] | type == "boolean") and
      ((.["pre-number"] // 0) | type == "number" and floor == . and . >= 0) and
      ((.["post-number"] // 0) | type == "number" and floor == . and . >= 0)
    )
  ' >/dev/null <<<"$snapshots" || return 65
  printf '%s\n' "$snapshots"
}

snapshots_list() {
  local state="$1"
  local snapshots pending_id

  snapshots="$(snapshots_read_raw)" || return $?
  pending_id="$(jq -r 'if .pending.kind == "pacman" then .pending.pre_snapshot_id else 0 end' <<<"$state")" || return $?
  jq -n --argjson raw "$snapshots" --argjson pending "$pending_id" '{
    snapshots: [
      $raw.root[] |
      ((.["pre-number"] // 0)) as $pre |
      ((.["post-number"] // 0)) as $post |
      (if .number == 0 then "current"
       elif $pre > 0 then "post"
       elif $post > 0 then "pre"
       else "single" end) as $type |
      {
        id: .number,
        type: $type,
        date: (.date // ""),
        description: (.description // ""),
        important: ((.userdata // "") | contains("important=yes")),
        pending: (.number == $pending and $pending > 0),
        read_only: .["read-only"],
        eligible: (.number > 0 and .["read-only"] == true and ($type == "pre" or $type == "single")),
        pre_number: $pre,
        post_number: $post
      }
    ]
  }'
}

snapshots_resolve() {
  local requested="$1"
  local state="$2"
  local listing pending_kind pinned resolved

  listing="$(snapshots_list "$state")" || return $?
  if [[ "$requested" == latest ]]; then
    pending_kind="$(jq -r '.pending.kind // empty' <<<"$state")"
    if [[ "$pending_kind" == pacman ]]; then
      pinned="$(jq -r '.pending.pre_snapshot_id' <<<"$state")"
      resolved="$(jq -r --argjson id "$pinned" '
        [.snapshots[] | select(.id == $id and .type == "pre" and .eligible)] |
        if length == 1 then .[0].id else empty end
      ' <<<"$listing")"
    elif [[ -z "$pending_kind" ]]; then
      resolved="$(jq -r '
        [.snapshots[] | select(.type == "pre" and .eligible)] |
        if length > 0 then (max_by(.id).id) else empty end
      ' <<<"$listing")"
    else
      return 75
    fi
  else
    [[ "$requested" =~ ^[1-9][0-9]*$ ]] || return 64
    resolved="$(jq -r --argjson id "$requested" '
      [.snapshots[] | select(.id == $id and .eligible)] |
      if length == 1 then .[0].id else empty end
    ' <<<"$listing")"
  fi
  [[ "$resolved" =~ ^[1-9][0-9]*$ ]] || return 65
  printf '%s\n' "$resolved"
}
