#!/usr/bin/env bash
# SD card checker for the team: verifies real capacity (f3), sequential speed (V/U/Class rating) and
# random IOPS (A1/A2) against what the card claims, and appends one row per card to a results CSV.
#
# Usage:
#   ./check_sd.sh [--quick|--speed] [mount_point]   test a card (no mount point = pick from inserted cards)
#   ./check_sd.sh --summary [csv ...]               count genuine/fake cards across result files
#
#   default : fills free space with test files and verifies them (keeps your files, ~1 hour per 64GB)
#   --quick : f3probe --destructive on the raw device (WIPES the card, minutes), then reformats it exFAT
#   --speed : read/write speed tests only, no fake check (keeps your files, ~3-5 min)
#
# Results go to $SD_RESULTS (default: sd_results.csv next to this script). Point it at a shared folder
# so the whole team's results land in one file, or collect everyone's files and run --summary on them.
# Needs (Ubuntu/Debian): sudo apt install f3 fio jq exfatprogs
set -euo pipefail

RESULTS="${SD_RESULTS:-$(dirname "$(readlink -f "$0")")/sd_results.csv}"
HEADER="date,tester,host,brand,claimed_gb,speed_class,app_class,seller,mode,device_gb,usable,capacity_verdict,write_mbs,read_mbs,speed_verdict,read_iops,write_iops,app_verdict,usb_mbps"

if [[ "${1:-}" == "--summary" ]]; then
  shift
  (( $# )) || set -- "$RESULTS"
  for f in "$@"; do [[ -f "$f" ]] || { echo "No results file: $f"; exit 1; }; done
  awk -F, 'FNR==1 {next}
    $12=="NOT-TESTED" {next}   # --speed runs never checked capacity, so they cannot count as genuine or fake
    {n++; v[$12]++; k=tolower($4" / "$8); t[k]++; if ($12=="FAKE") f[k]++}
    END {
      if (!n) {print "No results yet."; exit}
      printf "Cards tested: %d\n", n
      for (x in v) printf "  %-12s %d\n", x, v[x]
      print "\nBy brand / seller (fake / total):"
      for (x in t) printf "  %-45s %d / %d\n", x, f[x]+0, t[x]
    }' "$@"
  exit 0
fi

QUICK=0 SPEED_ONLY=0
case "${1:-}" in --quick) QUICK=1; shift ;; --speed) SPEED_ONLY=1; shift ;; esac

for c in f3write f3read f3probe fio jq mkfs.exfat; do
  command -v "$c" >/dev/null || { echo "$c not installed. Run: sudo apt install f3 fio jq exfatprogs"; exit 1; }
done

# A card is on a USB reader, a removable disk, or a built-in SD slot (mmcblk). Guards against wiping system drives.
is_card_disk() { [[ "$(lsblk -dno TRAN "/dev/$1")" == usb || "$(lsblk -dno RM "/dev/$1" | tr -d ' ')" == 1 || "$1" == mmcblk* ]]; }

MNT="${1:-}"
if [[ -z "$MNT" ]]; then
  mapfile -t cands < <(lsblk -Jpo NAME,PKNAME,MOUNTPOINT | jq -r '.blockdevices[] | recurse(.children[]?)
      | select(.pkname != null and .mountpoint != null) | "\(.pkname)\t\(.mountpoint)"' \
    | while IFS=$'\t' read -r pk mnt; do if is_card_disk "${pk##*/}"; then echo "$mnt"; fi; done)
  case ${#cands[@]} in
    0) echo "No mounted SD card found. Insert the card, let it mount, or pass its mount point."; exit 1 ;;
    1) MNT=${cands[0]} ;;
    *) echo "Several cards found, pick one:"; select MNT in "${cands[@]}"; do [[ -n "$MNT" ]] && break; done ;;
  esac
fi
mountpoint -q "$MNT" || { echo "$MNT is not a mount point"; exit 1; }

PART=$(findmnt -no SOURCE "$MNT")
PK=$(lsblk -no PKNAME "$PART")
[[ -n "$PK" ]] || { echo "$PART has no parent disk (card has no partition table?). Cannot continue."; exit 1; }
DISK=/dev/$PK
is_card_disk "$PK" || { echo "$DISK is not a USB/removable/SD-slot device. Refusing to test it."; exit 1; }
# Every test writes to the card; a locked card would otherwise run for an hour and test nothing.
if [[ "$(cat "/sys/block/$PK/ro")" == 1 ]] || findmnt -no OPTIONS "$MNT" | grep -qE '(^|,)ro(,|$)'; then
  echo "The card is read-only. Slide the lock switch on the card/adapter up (away from LOCK), re-insert it and retry."; exit 1
fi
# Create/check the results file now, so an hour-long test can't end with nowhere to save the result.
[[ -f "$RESULTS" ]] || echo "$HEADER" > "$RESULTS" 2>/dev/null || true
[[ -w "$RESULTS" ]] || { echo "Cannot write results file $RESULTS. Set SD_RESULTS to a writable path."; exit 1; }
LOG=$(mktemp -d)   # fresh per run, so a verdict can never come from an older run's log
trap 'rm -f "$MNT/fio_test.tmp"' EXIT   # don't leave the 1GB speed-test file behind on Ctrl+C

DEV_BYTES=$(lsblk -bdno SIZE "$DISK")
DEV_GB=$(awk -v b="$DEV_BYTES" 'BEGIN {printf "%.1f", b / 1e9}')
d=$(readlink -f "/sys/block/$PK"); while [[ $d != / && ! -f $d/speed ]]; do d=$(dirname "$d"); done
USB=$(cat "$d/speed" 2>/dev/null || echo n/a)

echo "== Card found =="
df -h "$MNT"
lsblk -o NAME,SIZE,MODEL,TRAN,RM "$DISK"
[[ $USB == n/a ]] || echo "Reader USB link: $USB Mbps $([[ $USB == 480 ]] && echo '(USB 2.0: speeds above ~35 MB/s cannot be measured)')"
echo

echo "== Describe the card (as printed on it / in the listing) =="
# read || exit: on Ctrl-D/closed input, stop instead of looping forever on the validation prompts.
# Strip CSV-breaking chars, and leading = + - @ which spreadsheets would run as a formula.
ask() { local a; read -rp "$1: " a || exit 1; a=${a:-$2}; tr -d ',"\r\n' <<<"$a" | sed 's/^[=+@-]*//'; }
speed_req() { case $1 in V90) echo 90 ;; V60) echo 60 ;; V30|U3) echo 30 ;; V10|U1|C10) echo 10 ;; V6|C6) echo 6 ;; C4) echo 4 ;; NONE) echo 0 ;; *) return 1 ;; esac; }
ME=${USER:-$(id -un)}   # $USER is unset in some shells (cron, containers); set -u would crash on it
TESTER=$(ask "Your name [$ME]" "$ME")
BRAND=$(ask "Brand (e.g. SanDisk, Samsung, Acer)" unknown)
while :; do CLAIMED=$(ask "Capacity printed on the card, in GB (e.g. 64)" ""); [[ "$CLAIMED" =~ ^[1-9][0-9]*$ ]] && break; echo "  Enter a number like 64 (no leading zero)."; done
while :; do SPEED=$(ask "Speed class: V10/V30/V60/V90, U1/U3, C10/C6/C4, or Enter for none" NONE); SPEED=${SPEED^^}
  REQ=$(speed_req "$SPEED") && break; echo "  Use one of: V10 V30 V60 V90 U1 U3 C10 C6 C4"; done
while :; do APP=$(ask "App class: A1/A2, or Enter for none" NONE); APP=${APP^^}; [[ $APP =~ ^(A1|A2|NONE)$ ]] && break; echo "  Use A1, A2 or Enter."; done
SELLER=$(ask "Bought from (e.g. Flipkart / Amazon + seller name)" unknown)
echo

# Real cards report slightly less than the label (64GB label ~ 62GB). Fakes usually report the label size, so f3 is the real test.
(( DEV_BYTES * 100 >= CLAIMED * 90 * 1000000000 )) || echo "WARNING: card reports only $DEV_GB GB but is labelled $CLAIMED GB."

if (( QUICK )); then
  # Any USB disk passes is_card_disk, so spell out what will be wiped in case it's a USB drive, not the card.
  echo "QUICK mode will ERASE EVERYTHING on $DISK: $(lsblk -dno SIZE,MODEL "$DISK" | xargs), $(df -h --output=used "$MNT" | tail -1 | xargs) currently used."
  echo "Make sure this is the SD card and not a USB drive with your data. It will be reformatted as exFAT."
  read -rp "Type the device name ($DISK) to confirm: " ans
  [[ "$ans" == "$DISK" ]] || { echo "Aborted."; exit 0; }
  sudo -v   # ask for the password now, not minutes later when the tests reach f3probe
elif (( SPEED_ONLY )); then
  echo "Speed test writes a 1GB temporary file (deleted afterwards). Existing files are not touched. ~3-5 min."
  echo "This does NOT check whether the card is fake; run without --speed for that."
  read -rp "Continue? [y/N] " ans
  [[ "$ans" == [yY] ]] || exit 0
else
  echo "This fills ALL free space on $MNT with test files (*.h2w), then verifies them."
  echo "Existing files are not touched. Takes roughly 1 hour per 64GB (longer on a slow reader)."
  # f3write only tests free space; space held by existing files is never checked.
  free_kb=$(df --output=avail -k "$MNT" | tail -1)
  (( free_kb * 1024 * 100 >= DEV_BYTES * 90 )) ||
    echo "WARNING: only $(( free_kb / 1000000 )) GB of $DEV_GB GB is free, so only that part gets tested. For a full check, empty the card or use --quick."
  read -rp "Continue? [y/N] " ans
  [[ "$ans" == [yY] ]] || exit 0
fi

# Speed tests run first, while mounted with free space. All use O_DIRECT so RAM cache doesn't inflate results.
fio_json() {  # $1 = rw mode, $2 = block size, rest = extra fio args; prints fio JSON
  local rw=$1 bs=$2; shift 2
  fio --name=t --filename="$MNT/fio_test.tmp" --size=1G --bs="$bs" --rw="$rw" --direct=1 --ioengine=libaio "$@" --output-format=json
}
W=err R=err RR=err RW=err SPEED_V=ERROR APP_V=ERROR
if (( $(df --output=avail -k "$MNT" | tail -1) < 1200000 )); then
  echo "Less than 1.2GB free; skipping speed tests."
else
  echo "== Speed tests (fio, ~3-5 min) =="
  # A failed speed test must not stop the capacity test, which is the one that decides fake/genuine.
  # jq -e: a missing field fails here instead of reaching the arithmetic below as "null".
  if echo "  Sequential write (1GB, 1MB blocks)..." &&
     W=$(fio_json write 1M --iodepth=4 | jq -e '.jobs[0].write.bw_bytes/1e5 | floor/10') && echo "    $W MB/s" &&
     echo "  Sequential read  (1GB, 1MB blocks)..." &&
     R=$(fio_json read 1M --iodepth=4 | jq -e '.jobs[0].read.bw_bytes/1e5 | floor/10') && echo "    $R MB/s" &&
     echo "  Random read  (4KB blocks, 60s)..." &&
     RR=$(fio_json randread 4k --iodepth=32 --runtime=60 --time_based | jq -e '.jobs[0].read.iops | floor') && echo "    $RR IOPS" &&
     echo "  Random write (4KB blocks, 60s)..." &&
     RW=$(fio_json randwrite 4k --iodepth=32 --runtime=60 --time_based | jq -e '.jobs[0].write.iops | floor') && echo "    $RW IOPS"; then
    WI=${W%.*} RI=${R%.*}   # whole MB/s for bash integer comparisons
    # Genuine cards read clearly faster than they write. If read < 1.5x write, both are stuck at the
    # reader's ceiling, so a low result says nothing about the card: report INCONCLUSIVE, not FAIL.
    LIMITED=0; (( RI * 10 < WI * 15 )) && LIMITED=1
    if   (( REQ == 0 )); then SPEED_V=n/a
    elif (( WI >= REQ )); then SPEED_V=PASS
    elif (( LIMITED )) || [[ $USB == 480 && $REQ -gt 30 ]]; then SPEED_V=INCONCLUSIVE
    else SPEED_V=FAIL; fi
    case $APP in A2) AR=4000 AW=2000 ;; A1) AR=1500 AW=500 ;; *) AR=0 AW=0 ;; esac
    if   (( AR == 0 )); then APP_V=n/a
    elif (( RR >= AR && RW >= AW )); then APP_V=PASS
    elif (( LIMITED )) || [[ $APP == A2 && $USB != n/a ]]; then APP_V=INCONCLUSIVE   # A2 needs Command Queue, which USB readers lack
    else APP_V=BELOW; fi
  else
    W=err R=err RR=err RW=err   # don't report half-finished numbers
    echo "Speed test failed (see error above); continuing with the capacity test."
  fi
  rm -f "$MNT/fio_test.tmp"
fi
echo

USABLE=unknown F3W="" F3R=""
if (( SPEED_ONLY )); then
  CAP_V=NOT-TESTED
elif (( QUICK )); then
  sync
  sudo umount "$PART"
  echo "== Capacity test: f3probe (destructive) =="
  # || true: card is already unmounted/wiped, so always continue to reformat even if f3probe errors.
  sudo f3probe --destructive --time-ops "$DISK" | tee "$LOG/f3probe.log" || true
  USABLE=$(sed -n 's/.*\*Usable\* size: *\([0-9.]* [A-Za-z]*\).*/\1/p' "$LOG/f3probe.log")
  if   grep -q "is the real thing" "$LOG/f3probe.log"; then CAP_V=GENUINE
  elif grep -q "Bad news" "$LOG/f3probe.log"; then CAP_V=FAKE
  else CAP_V=NO-VERDICT; fi

  echo "== Reformatting $DISK as exFAT =="
  # Desktop automount can grab the card during f3probe; release it so the kernel can re-read the new table.
  sudo umount "$DISK"?* 2>/dev/null || true
  echo 'type=7' | sudo sfdisk --wipe always "$DISK"   # one MBR partition, type 7 = exFAT
  sudo partprobe "$DISK"; sudo udevadm settle
  NEWPART=$(lsblk -lnpo NAME "$DISK" | sed -n 2p)
  # Formatting at the kernel's stale offset would leave the card unreadable, so check the kernel saw the new table.
  want=$(sudo sfdisk -d "$DISK" | sed -n 's/.*start= *\([0-9]*\).*/\1/p' | head -1)
  if [[ -n "$NEWPART" && "$want" == "$(cat "/sys/class/block/${NEWPART##*/}/start")" ]]; then
    sudo mkfs.exfat -L SDCARD "$NEWPART"
  else
    echo "WARNING: kernel did not pick up the new partition. Re-plug the card and run: sudo mkfs.exfat -L SDCARD ${NEWPART:-${DISK}1}"
  fi
else
  echo "== Capacity test: f3write + f3read =="
  # || true: a fake card can make f3write/f3read error out; still read back and judge what was written.
  f3write "$MNT" | tee "$LOG/f3write.log" || true
  sync   # f3read bypasses the page cache itself (posix_fadvise), so no cache drop is needed
  f3read "$MNT" | tee "$LOG/f3read.log" || true
  USABLE=$(sed -n 's/.*Data OK: *\([0-9.]* [A-Za-z]*\).*/\1/p' "$LOG/f3read.log")
  # Whole-card averages: closer to real sustained speed than the 1GB fio test.
  F3W=$(sed -n 's/.*Average writing speed: *//p' "$LOG/f3write.log")
  F3R=$(sed -n 's/.*Average reading speed: *//p' "$LOG/f3read.log")
  # Three-way so a crashed/interrupted f3read never reads as "fake". f3read prints "Data LOST: <size> (<n> sectors)".
  # GENUINE also needs Data OK > 0: with nothing written, f3read still reports "Data LOST: ... (0 sectors)".
  if   grep -qE "Data LOST: .*\(0 sectors\)" "$LOG/f3read.log" &&
       grep -qE "Data OK: .*\([1-9][0-9]* sectors\)" "$LOG/f3read.log"; then CAP_V=GENUINE
  elif grep -qE "Data LOST: .*\([1-9][0-9]* sectors\)" "$LOG/f3read.log"; then CAP_V=FAKE
  else CAP_V=NO-VERDICT; fi
fi

[[ -f "$RESULTS" ]] || echo "$HEADER" > "$RESULTS"
echo "$(date +%F\ %H:%M),$TESTER,$(hostname),$BRAND,$CLAIMED,$SPEED,$APP,$SELLER,$( ((QUICK)) && echo quick || { ((SPEED_ONLY)) && echo speed || echo full; }),$DEV_GB,${USABLE:-unknown},$CAP_V,$W,$R,$SPEED_V,$RR,$RW,$APP_V,$USB" >> "$RESULTS"

echo
echo "================ RESULT: $BRAND ${CLAIMED}GB $SPEED $APP ================"
case $CAP_V in
  GENUINE)    echo "Capacity : GENUINE (usable ${USABLE:-?})" ;;
  FAKE)       echo "Capacity : FAKE - only ${USABLE:-?} actually works. Request a refund." ;;
  NO-VERDICT) echo "Capacity : NO VERDICT - the test did not finish, see errors above. Logs: $LOG" ;;
  NOT-TESTED) echo "Capacity : not tested (--speed run). Run without --speed to check for a fake card." ;;
esac
echo "Speed    : write $W MB/s, read $R MB/s -> $SPEED_V $( ((REQ)) && echo "(needs >= $REQ MB/s write)")"
[[ -n "$F3W$F3R" ]] && echo "           whole-card average: write ${F3W:-?}, read ${F3R:-?}"
echo "App (4K) : read $RR / write $RW IOPS -> $APP_V"
[[ $SPEED_V == INCONCLUSIVE || $APP_V == INCONCLUSIVE ]] &&
  echo "INCONCLUSIVE = your card reader is the bottleneck. Retest with a USB 3.0 UHS-I reader or a laptop SD slot."
echo "Only the capacity result decides fake vs genuine. Saved to $RESULTS"
(( QUICK )) && echo "Re-plug the card to mount it."

if (( ! QUICK && ! SPEED_ONLY )); then
  read -rp "Delete the test files (*.h2w) now? [Y/n] " del
  [[ "$del" == [nN] ]] || rm -f "$MNT"/*.h2w
fi
