#!/usr/bin/env bash
# Release version rules shared by the Release workflow, release.sh, and build-app.sh.
#
# Releases are YYYY.M.D.N, tagged vYYYY.M.D.N: the America/Los_Angeles date on
# which the Release workflow computed the version, then the release's ordinal on
# that day. Month, day, and N have no leading zeros. Legacy vX.Y.Z tags remain
# valid predecessors and describe targets, and always order below date tags.

RELEASE_TIME_ZONE="America/Los_Angeles"

release_date_exists() {
  local year="$1" month="$2" day="$3" days=31
  case "$month" in
    4|6|9|11) days=30 ;;
    2)
      days=28
      if (( year % 4 == 0 && (year % 100 != 0 || year % 400 == 0) )); then
        days=29
      fi
      ;;
  esac
  [ "$day" -le "$days" ]
}

is_date_release_version() {
  local pattern='^([1-9][0-9]{3})\.(1[0-2]|[1-9])\.(3[01]|[12][0-9]|[1-9])\.[1-9][0-9]*$'
  [[ "$1" =~ $pattern ]] || return 1
  release_date_exists "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
}

is_legacy_release_version() {
  local pattern='^[0-9]+\.[0-9]+\.[0-9]+$'
  [[ "$1" =~ $pattern ]]
}

is_release_tag() {
  [[ "$1" == v* ]] || return 1
  is_date_release_version "${1#v}" || is_legacy_release_version "${1#v}"
}

# Y.M.D -> YYYYMMDD, for ordering dates whose components have no leading zeros.
release_date_ordinal() {
  local year month day
  IFS=. read -r year month day <<< "$1"
  printf '%d\n' "$((year * 10000 + month * 100 + day))"
}

# Print the highest release tag among the tag names on stdin; ignore other tags.
latest_release_tag() {
  local tag version
  while IFS= read -r tag || [ -n "$tag" ]; do
    version="${tag#v}"
    [ "$tag" != "$version" ] || continue
    if is_date_release_version "$version"; then
      printf '1 %s %s\n' "${version//./ }" "$tag"
    elif is_legacy_release_version "$version"; then
      printf '0 %s 0 %s\n' "${version//./ }" "$tag"
    fi
  done | sort -k1,1n -k2,2n -k3,3n -k4,4n -k5,5n | tail -n 1 | awk '{ print $NF }'
}

# Print today's release date (Y.M.D) in RELEASE_TIME_ZONE.
pacific_release_date() {
  local stamp pattern='^([0-9]{4}) ([0-9]{2}) ([0-9]{2}) (PST|PDT)$'
  # BSD date has no %-m, so strip leading zeros arithmetically.
  stamp="$(TZ="$RELEASE_TIME_ZONE" date +'%Y %m %d %Z')" || return 1
  [[ "$stamp" =~ $pattern ]] || {
    echo "error: could not read today's date in $RELEASE_TIME_ZONE (got '$stamp')" >&2
    return 1
  }
  printf '%d.%d.%d\n' \
    "$((10#${BASH_REMATCH[1]}))" "$((10#${BASH_REMATCH[2]}))" "$((10#${BASH_REMATCH[3]}))"
}

# Fail when a version's date is after today (Y.M.D).
check_release_version_date() {
  local version="$1" today="$2"
  if [ "$(release_date_ordinal "${version%.*}")" -gt "$(release_date_ordinal "$today")" ]; then
    echo "error: v$version is dated after today ($today in $RELEASE_TIME_ZONE)" >&2
    return 1
  fi
}

# Print the version that follows latest_tag on today (Y.M.D): the next ordinal
# when latest_tag is from today, otherwise today's first release.
next_release_version() {
  local latest_tag="$1" today="$2" latest
  is_date_release_version "$today.1" || {
    echo "error: invalid release date '$today'" >&2
    return 1
  }
  latest="${latest_tag#v}"
  if [[ "$latest_tag" == v* ]] && is_date_release_version "$latest"; then
    if [ "${latest%.*}" = "$today" ]; then
      printf '%s.%d\n' "$today" "$((${latest##*.} + 1))"
      return
    fi
    check_release_version_date "$latest" "$today" || {
      echo "error: refusing to publish a version below latest release $latest_tag" >&2
      return 1
    }
  elif ! is_release_tag "$latest_tag"; then
    echo "error: '$latest_tag' is not a release tag" >&2
    return 1
  fi
  printf '%s.1\n' "$today"
}
