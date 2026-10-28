# SD Card Checker

Finds fake and underperforming SD cards. Fake cards are cheap small cards (often 8–16GB) reprogrammed
to report a large size (128GB, 256GB…). They look normal until you store more than their real size,
then your files silently get corrupted.

`check_sd.sh` tests a card against what its label claims and saves the result to a shared CSV, so the
team can see how many cards are fake and which brands/sellers they came from.

## Setup (once, Ubuntu/Debian)

```bash
sudo apt install f3 fio jq exfatprogs
chmod +x check_sd.sh
```

## Test a card

1. Insert the card and let it mount (it shows up in the file manager).
2. Run one of:

| Command | Time | Erases the card? | Measures |
|---|---|---|---|
| `./check_sd.sh` | ~1 hour per 64GB | **No**, existing files are kept | capacity, speed, A1/A2 |
| `./check_sd.sh --quick` | ~5–10 min | **Yes, everything**, then reformats it exFAT | capacity, speed, A1/A2 |

Use `--quick` for new, empty cards. The script finds the inserted card itself (or lets you pick if there
are several); you can also pass the mount point: `./check_sd.sh /media/$USER/MYCARD`.

3. Answer the questions about the card, exactly as printed on the card / product listing:

```
Your name [asha]:
Brand (e.g. SanDisk, Samsung, Acer): Acer
Capacity printed on the card, in GB (e.g. 64): 64
Speed class: V10/V30/V60/V90, U1/U3, C10/C6/C4, or Enter for none: V30
App class: A1/A2, or Enter for none: A1
Bought from (e.g. Flipkart / Amazon + seller name): Flipkart RetailNet
```

`--quick` then asks you to type the device name (e.g. `/dev/sda`) to confirm the wipe, and your sudo password.

## Reading the result

```
================ RESULT: Acer 64GB V30 A1 ================
Capacity : GENUINE (usable 58.24 GB)
Speed    : write 9 MB/s, read 9 MB/s -> INCONCLUSIVE (needs >= 30 MB/s write)
App (4K) : read 1047 / write 485 IOPS -> INCONCLUSIVE
```

**Capacity is the only line that decides fake vs genuine.**

| Capacity | Meaning |
|---|---|
| `GENUINE` | Every byte the card claims works. A "64GB" card shows ~58 GiB / ~62 GB; that is normal. |
| `FAKE` | Only the "usable" size actually stores data. Return the card / request a refund. |
| `NO-VERDICT` | The test didn't finish (error, unplugged, Ctrl+C). Run it again. |

| Speed / App | Meaning |
|---|---|
| `PASS` | Meets its V/U/Class (sequential write) or A1/A2 (random 4K IOPS) rating. |
| `FAIL` / `BELOW` | Card is slower than its rating, measured in a reader that was fast enough. |
| `INCONCLUSIVE` | **Your card reader was the bottleneck**, not the card. Retest in a USB 3.0 UHS-I reader or a laptop SD slot. |
| `n/a` | No rating was entered. |

Minimums used: V10/U1/C10 = 10 MB/s, V30/U3 = 30 MB/s, V60 = 60, V90 = 90 write.
A1 = 1500 read / 500 write IOPS, A2 = 4000 / 2000.

### About card readers

Cheap USB 2.0 readers often cap every card at ~10 MB/s (or ~35 MB/s at best), so they cannot verify
V30 and above. A2 speeds also need "Command Queue" support that USB readers lack, so A2 cards on USB
are usually `INCONCLUSIVE`. The script shows the reader's USB link speed (480 = USB 2.0, 5000+ = USB 3).
None of this affects the capacity verdict.

## Team results

Every run appends one row to `sd_results.csv` next to the script. To collect everyone's results in one
place, either:

- point everyone at a shared folder: `SD_RESULTS=/path/to/shared/sd_results.csv ./check_sd.sh`, or
- have each person send their `sd_results.csv` and summarise them together.

```bash
./check_sd.sh --summary                      # your own results
./check_sd.sh --summary asha.csv ravi.csv    # several people's files
```

```
Cards tested: 12
  GENUINE      9
  FAKE         3

By brand / seller (fake / total):
  sandisk / flipkart retailnet                  2 / 4
  acer / amazon cloudtail                       0 / 3
```

CSV columns: `date, tester, host, brand, claimed_gb, speed_class, app_class, seller, mode, device_gb,
usable, capacity_verdict, write_mbs, read_mbs, speed_verdict, read_iops, write_iops, app_verdict, usb_mbps`.

## Notes

- Only USB, removable or built-in SD-slot devices are accepted, so the script can't test or wipe a system disk.
- The speed test writes a 1GB file; cards with less than 1.2GB free skip it.
- Full mode leaves test files (`*.h2w`) on the card; the script offers to delete them at the end.
- If two people write to the same shared CSV at the exact same moment, a row can be garbled; per-person files + `--summary` avoids this.
- If `--quick` prints "kernel did not pick up the new partition", re-plug the card and run the `mkfs.exfat` command it shows.
