#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Dryrun tests for encapsule. Needs podman and local images; skips the rest.
# Usage: test/run-tests.sh

set -u

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root" || exit 1

npass=0
nfail=0
nskip=0

ok() {
  echo "ok - $*"
  npass=$((npass + 1))
}

not_ok() {
  echo "FAIL - $*"
  nfail=$((nfail + 1))
}

skip() {
  local name=$1
  shift
  echo "SKIP - $name # $*"
  nskip=$((nskip + 1))
}

assert_contains() {
  local hay=$1 needle=$2 name=$3
  if [[ $hay == *"$needle"* ]]; then
    ok "$name"
  else
    not_ok "$name (missing: $needle)"
  fi
}

assert_not_contains() {
  local hay=$1 needle=$2 name=$3
  if [[ $hay == *"$needle"* ]]; then
    not_ok "$name (unexpected: $needle)"
  else
    ok "$name"
  fi
}

debug_field() {
  local out=$1 key=$2
  printf '%s\n' "$out" | grep -E "debug: ${key}: " | head -n1 | sed "s/.*debug: ${key}: //" | tr -d '\r'
}

if [[ -n ${ENCAPSULE:-} ]]; then
  # shellcheck disable=SC2206
  ENC=($ENCAPSULE)
elif command -v cabal >/dev/null 2>&1 && [[ -f encapsule.cabal ]]; then
  ENC=(cabal run -v0 encapsule --)
elif command -v encapsule >/dev/null 2>&1; then
  ENC=(encapsule)
else
  echo "error: encapsule not found (set ENCAPSULE, install it, or run from the repo with cabal)" >&2
  exit 1
fi

echo "# using: ${ENC[*]}"

image_exists() {
  podman image exists "$1" >/dev/null 2>&1
}

dryrun() {
  "${ENC[@]}" run --dryrun --debug --no-skel "$@"
}

HOST_UID=$(id -u)
HOST_USER=$(id -un)
UBUNTU_IMG=ubuntu:latest
FEDORA_IMG=fedora:latest

if ! command -v podman >/dev/null 2>&1; then
  skip "podman dryrun tests" "podman not found"
  echo "# $npass passed, $nfail failed, $nskip skipped"
  exit 0
fi

testdir=$(mktemp -d /tmp/encapsule-test.XXXXXX)
trap 'rm -rf "$testdir"' EXIT
mkdir -p "$testdir/proj"
home_tmp=$testdir/home
mkdir -p "$home_tmp"

generic_img=
for img in "$UBUNTU_IMG" "$FEDORA_IMG"; do
  if image_exists "$img"; then
    generic_img=$img
    break
  fi
done

if [[ -z $generic_img ]]; then
  skip "keep-id / naming / --user root" "no $UBUNTU_IMG or $FEDORA_IMG image"
else
  out=$(dryrun "$generic_img" 2>&1) || true
  if [[ $out != *'podman run'* ]]; then
    not_ok "dryrun $generic_img prints podman run"
    printf '%s\n' "$out" | sed 's/^/# /'
  else
    ok "dryrun $generic_img prints podman run"
    assert_contains "$out" '--userns=keep-id' "$generic_img keep-id"
  fi

  out=$(dryrun --name "testhost$$" "$generic_img" 2>&1) || true
  assert_contains "$out" "--name encapsule-testhost$$" "--name testhost"

  out=$(dryrun --name '^bare-encap-test' "$generic_img" 2>&1) || true
  assert_contains "$out" '--name bare-encap-test' "--name ^bare-encap-test"

  out=$(dryrun --project "$testdir/proj" "$generic_img" 2>&1) || true
  assert_contains "$out" '--workdir' "--project sets workdir"
  assert_contains "$out" '--name encapsule-' "--project names container"
  assert_contains "$out" '-proj' "--project includes directory name"

  runuser=$(debug_field "$out" runuser)
  if [[ $runuser == True ]]; then
    out=$(dryrun --user root "$generic_img" 2>&1) || true
    assert_contains "$out" 'runuser -u root' "--user root uses runuser"
  else
    skip "--user root / runuser" "$generic_img has no runuser"
  fi
fi

if ! image_exists "$UBUNTU_IMG"; then
  skip "ubuntu UID user/home" "no $UBUNTU_IMG image"
elif [[ $HOST_UID != 1000 ]]; then
  skip "ubuntu UID user/home" "host uid is $HOST_UID, not 1000"
else
  out=$(dryrun "$UBUNTU_IMG" 2>&1) || true
  img_user=$(debug_field "$out" 'image user')
  if [[ $img_user != ubuntu ]]; then
    skip "ubuntu UID user/home" "image user is ${img_user:-unknown}, not ubuntu"
  else
    assert_contains "$out" 'runuser -u ubuntu' "ubuntu runuser -u ubuntu"
    assert_not_contains "$out" "runuser -u $HOST_USER" "ubuntu does not use host username"
    assert_contains "$out" '--workdir /home/ubuntu' "ubuntu --workdir /home/ubuntu"
    hosthome=$(debug_field "$out" HOME)
    if [[ -n $hosthome ]]; then
      assert_not_contains "$out" "-e=HOME=$hosthome" "ubuntu does not override HOME"
    else
      not_ok "ubuntu debug HOME line"
    fi
    ctrhome=$(debug_field "$out" 'container home')
    [[ $ctrhome == /home/ubuntu ]] && ok "ubuntu container home /home/ubuntu" \
      || not_ok "ubuntu container home (got: ${ctrhome:-empty})"

    out=$(dryrun --home "$home_tmp" "$UBUNTU_IMG" 2>&1) || true
    home_abs=$(realpath "$home_tmp")
    assert_contains "$out" "$home_abs:/home/ubuntu" "--home mounts on /home/ubuntu"
    if [[ -n ${hosthome:-} ]]; then
      assert_not_contains "$out" "$home_abs:$hosthome" "--home does not mount on host HOME"
    fi
  fi
fi

if ! image_exists "$FEDORA_IMG"; then
  skip "fedora HOME fallback" "no $FEDORA_IMG image"
else
  out=$(dryrun "$FEDORA_IMG" 2>&1) || true
  img_user=$(debug_field "$out" 'image user')
  passwd_home=$(debug_field "$out" 'passwd home')
  if [[ $img_user != '(none)' ]]; then
    skip "fedora HOME fallback" "image has uid user $img_user"
  else
    runuser=$(debug_field "$out" runuser)
    user=$(debug_field "$out" user)
    hosthome=$(debug_field "$out" HOME)
    [[ $user == "$HOST_USER" ]] && ok "fedora user is host name" \
      || not_ok "fedora user (got: ${user:-empty}, expected $HOST_USER)"
    if [[ $runuser == True && -n $hosthome ]]; then
      assert_contains "$out" "runuser -u $HOST_USER" "fedora runuser -u host user"
      assert_contains "$out" "-e=HOME=$hosthome" "fedora overrides HOME"
    elif [[ $runuser != True ]]; then
      skip "fedora runuser HOME" "fedora image has no runuser"
    else
      not_ok "fedora debug HOME line"
    fi
    [[ $passwd_home == '(none)' ]] && ok "fedora passwd home dummy" \
      || not_ok "fedora passwd home (got: ${passwd_home:-empty})"
  fi
fi

sudo_img=$generic_img
if [[ -n $sudo_img ]]; then
  out=$(dryrun "$sudo_img" 2>&1) || true
  have_sudo=$(debug_field "$out" sudo)
  if [[ $have_sudo == True ]]; then
    assert_contains "$out" 'NOPASSWD:ALL' "$sudo_img sudoers when sudo present"
    out=$(dryrun --no-sudo "$sudo_img" 2>&1) || true
    assert_contains "$out" 'rm -f /usr/bin/sudo' "--no-sudo removes sudo"
    assert_not_contains "$out" 'NOPASSWD:ALL' "--no-sudo skips sudoers"
  elif [[ $have_sudo == False ]]; then
    assert_not_contains "$out" 'NOPASSWD:ALL' "$sudo_img no sudoers when no sudo"
    out=$(dryrun --no-sudo "$sudo_img" 2>&1) || true
    assert_not_contains "$out" 'rm -f /usr/bin/sudo' "--no-sudo is a no-op without sudo"
  else
    not_ok "debug sudo line for $sudo_img (got: '${have_sudo:-empty}')"
  fi
else
  skip "sudo setup" "no test image"
fi

if [[ -t 0 && -n $generic_img ]]; then
  if command -v timeout >/dev/null 2>&1; then
    live=$(timeout 60 "${ENC[@]}" run --no-skel "$generic_img" id -un 2>&1) || true
  else
    live=$("${ENC[@]}" run --no-skel "$generic_img" id -un 2>&1) || true
  fi
  if [[ -n $live ]]; then
    ok "live run $generic_img id -un"
  else
    not_ok "live run $generic_img id -un"
  fi
else
  skip "live smoke" "not a TTY or no image"
fi

echo "# $npass passed, $nfail failed, $nskip skipped"
if [[ $nfail -gt 0 ]]; then
  exit 1
fi
exit 0
