#!/usr/bin/env bash
# Checks an SD card for fake capacity, speed and A2 rating using f3 (Fight Flash Fraud) and fio.
# Usage: ./check_sd.sh [--quick] [mount_point]   (default: /media/rohitdarekar/disk)
#   default : fills free space with test files and verifies them (non-destructive, hours)
#   --quick : f3probe --destructive on the raw device (WIPES the card, minutes), then reformats it exFAT
set -euo pipefail

QUICK=0
[[ "${1:-}" == "--quick" ]] && { QUICK=1; shift; }
MNT="${1:-/media/rohitdarekar/disk}"

for c in f3write f3probe fio jq mkfs.exfat; do
  command -v "$c" >/dev/null || { echo "$c not installed. Run: sudo apt install f3 fio jq exfatprogs"; exit 1; }
done
mountpoint -q "$MNT" || { echo "$MNT is not a mount point"; exit 1; }

PART=$(findmnt -no SOURCE "$MNT")
PK=$(lsblk -no PKNAME "$PART")
[[ -n "$PK" ]] || { echo "$PART has no parent disk (card has no partition table?). Cannot continue."; exit 1; }
DISK=/dev/$PK

echo "== Card info =="
df -h "$MNT"
lsblk -o NAME,SIZE,MODEL,TRAN,RM "$DISK"
echo
if (( QUICK )); then
  # Refuse anything that isn't a removable/USB disk, so a wrong mount point can't wipe a system drive.
  [[ "$(lsblk -dno TRAN "$DISK")" == usb || "$(lsblk -dno RM "$DISK" | tr -d ' ')" == 1 ]] \
    || { echo "$DISK is not removable/USB. Refusing to wipe it."; exit 1; }
  echo "QUICK mode will ERASE EVERYTHING on $DISK and reformat it as exFAT."
  read -rp "Type the device name ($DISK) to confirm: " ans
  [[ "$ans" == "$DISK" ]] || { echo "Aborted."; exit 0; }
else
  echo "This fills ALL free space on $MNT with test files (*.h2w), then verifies them."
  echo "Existing files are not touched. ~256GB can take several hours."
  read -rp "Continue? [y/N] " ans
  [[ "$ans" == [yY] ]] || exit 0
fi

# A2 check first, while mounted with free space. Spec minimums (4KiB random): A2 = 4000 read / 2000 write IOPS, A1 = 1500 / 500.
echo "== A2 random IOPS test (fio, ~2 min) =="
fio_iops() {  # $1 = randread|randwrite
  fio --name=a2 --filename="$MNT/fio_a2.tmp" --size=1G --bs=4k --rw="$1" --direct=1 \
      --ioengine=libaio --iodepth=32 --runtime=60 --time_based --output-format=json \
    | jq -r "if \"$1\" == \"randread\" then .jobs[0].read.iops else .jobs[0].write.iops end | floor"
}
rr=$(fio_iops randread); rw=$(fio_iops randwrite)
rm -f "$MNT/fio_a2.tmp"
echo "Random read : $rr IOPS (A2 needs >=4000)"
echo "Random write: $rw IOPS (A2 needs >=2000)"
if   (( rr >= 4000 && rw >= 2000 )); then echo "Meets A2."
elif (( rr >= 1500 && rw >= 500 ));  then echo "Only A1 level."
else echo "Below A1."; fi
echo "Note: A2 speed needs host Command Queue support. Most USB card readers lack it, so a genuine A2 card often scores A1-level here. Low IOPS alone is not proof of fake."
echo

if (( QUICK )); then
  sync
  sudo umount "$PART"
  echo "== f3probe (destructive) =="
  # || true: card is already unmounted/wiped, so always continue to reformat even if f3probe errors.
  sudo f3probe --destructive --time-ops "$DISK" | tee /tmp/f3probe.log || true
  echo
  echo "== Verdict =="
  if grep -q "is the real thing" /tmp/f3probe.log; then
    echo "GENUINE capacity."
  elif grep -q "Bad news" /tmp/f3probe.log; then
    echo "FAKE or FAULTY: see 'usable size' above. Request a refund."
  else
    echo "f3probe did not finish; no verdict. Check the error above."
  fi
  echo "== Reformatting $DISK as exFAT =="
  echo 'type=7' | sudo sfdisk --wipe always "$DISK"   # one MBR partition, type 7 = exFAT
  sudo partprobe "$DISK"; sudo udevadm settle
  NEWPART=$(lsblk -lnpo NAME "$DISK" | sed -n 2p)
  [[ -n "$NEWPART" ]] || { echo "New partition not found. Re-plug the card and run: sudo mkfs.exfat ${DISK}1"; exit 1; }
  sudo mkfs.exfat -L SDCARD "$NEWPART"
  echo "Done. Re-plug the card to mount it."
  exit 0
fi

f3write "$MNT" | tee /tmp/f3write.log
sync
# Drop the page cache so f3read hits the card, not RAM (needs sudo; harmless if it fails).
sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches' 2>/dev/null || echo "(could not drop caches; read speed may look inflated)"
f3read "$MNT" | tee /tmp/f3read.log

echo
echo "== Verdict =="
grep -i "Data LOST" /tmp/f3read.log || true
# Three-way so a crashed/interrupted f3read never reads as "fake". f3read prints "Data LOST: <size> (<n> sectors)".
if grep -qE "Data LOST: .*\(0 sectors\)" /tmp/f3read.log; then
  echo "GENUINE capacity: all written data read back correctly."
elif grep -q "Data LOST:" /tmp/f3read.log; then
  echo "FAKE or FAULTY: some data was lost/corrupted. Request a refund."
else
  echo "f3read did not finish; no verdict. Check the error above."
fi
grep -i "Average writing speed" /tmp/f3write.log || true
grep -i "Average reading speed" /tmp/f3read.log || true
echo "V30 means >=30 MB/s sustained write. A USB 2.0 reader caps at ~35 MB/s, so use a USB 3 reader for a fair test."

read -rp "Delete the test files (*.h2w) now? [Y/n] " del
[[ "$del" == [nN] ]] || rm -f "$MNT"/*.h2w
