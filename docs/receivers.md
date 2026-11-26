# Receivers

Raspberry-LRPT records with SatDump 1.2.3, which talks to the receiver itself. The install asks
which receiver the station has, then sets up only what that receiver needs. These are the same
receivers raspberry-noaa-v2 supported:

| # | Receiver | `receiver_type` | Gain setting means | Sample rate |
|---|---|---|---|---|
| 1 | RTL-SDR (RTL-SDR Blog V3/V4, Nooelec and other RTL2832U sticks) | `rtlsdr` | 0–49.6 dB | 1.024 MS/s |
| 2 | Airspy Mini | `airspy_mini` | 0–21 (linearity gain steps) | 3 MS/s |
| 3 | Airspy R2 | `airspy_r2` | 0–21 (linearity gain steps) | 2.5 MS/s |
| 4 | Airspy HF+ Discovery | `airspy_hf_plus_discovery` | not used (automatic gain) | 192 kS/s |
| 5 | HackRF One | `hackrf` | 0–102 dB: the LNA first (0–40, 8 dB steps), the rest on the VGA (0–62, 2 dB steps) | 2 MS/s |
| 6 | SDRplay RSP1, RSP1A, RSP1B, RSP2, RSPduo, RSPdx | `sdrplay` | IF gain 20–59 (LNA state 5) | 2 MS/s |
| 7 | MSi2500/MSi001 receivers ("SDRplay clones", MiriSDR) | `mirisdr` | 0–100 dB, in 10 dB steps | 2 MS/s |

## Choosing it

A first install asks for the receiver with a numbered list; type its number. It then suggests a
gain for that receiver and checks the range. To change receiver later:

```bash
cd ~/raspberry-lrpt && ./install_and_upgrade.sh     # answer n to "Keep these settings?"
sudo reboot                                        # so the kernel drivers are set up for it
```

## What the install sets up

| Receiver | Set up by the install |
|---|---|
| RTL-SDR | Debian's DVB driver blacklisted; the **RTL-SDR Blog driver** (it supports the RTL-SDR Blog V4) built as `librtlsdr0` and `rtl-sdr` packages and installed with apt, with its udev rules |
| Airspy, Airspy HF+ | the `airspy` or `airspyhf` tools, Airspy udev rules, the `airspy` kernel module blacklisted |
| HackRF | the `hackrf` tools and their udev rules |
| MiriSDR | the `msi001`/`msi2500` kernel drivers blacklisted and unloaded, udev rules for MSi2500 receivers |
| SDRplay | the same blacklist, **SDRplay's API** and **SatDump's SDRplay plugin** (below) |

SatDump's plugins for RTL-SDR, Airspy, HackRF and MiriSDR come with the SatDump package.

## RTL-SDR: the RTL-SDR Blog driver

The install builds the [RTL-SDR Blog driver](https://github.com/rtlsdrblog/rtl-sdr-blog) with its
own Debian packaging into `librtlsdr0` and `rtl-sdr` packages, from a pinned commit, and installs
them with apt (about a minute on a Pi). It supports every RTL2832U stick, including the RTL-SDR
Blog V4, on Bookworm and Trixie. Their version starts with `1:` so apt keeps them over Debian's own
librtlsdr. `dpkg -l librtlsdr0` shows it (`1:0.7.0~rtlsdrblog1+git…`). Stations from before v1.24.0
had a build in `/usr/local`; the install removes it.

## SDRplay

SDRplay receivers need SDRplay's own API, which is closed source, so:

- The setup questions ask you to accept **SDRplay's licence** (https://www.sdrplay.com/api/). Without
  it the install stops at the SDRplay step.
- The install downloads the API (version 3.15.2) from sdrplay.com, checks its SHA-256, and installs
  it as SDRplay's own installer would: the library and headers in `/usr/local`, SDRplay's udev rules,
  and `sdrplay_apiService` as the `sdrplay` systemd service. The licence text is kept in
  `/usr/local/share/doc/sdrplay_api/`.
- The SatDump package has no SDRplay plugin, so the install builds it on the Pi from SatDump's
  source (the same commit as the package) in a minute or two. It is rebuilt only when the SatDump
  version changes.

The gain setting is the IF gain (20–59). The LNA state is 5, which suits the RSP1A, RSP1B, RSP2
and RSPduo. An RSPdx has more LNA states; give it more LNA gain with
`sdr_extra_options: '--lna_gain 20'` in `config/settings.yml`.

### When an SDRplay receiver gets no pictures

Users have run the RSP1A with this station: SatDump finds it and records from it. When passes
still come out empty, go through these in order.

**"Could not find a handler for source type : sdrplay"** in the log, right after "SDRPlay API is
ready!", means SatDump loaded SDRplay's API but the API listed no receiver, so the pass stopped at
once. Since v1.50.3 each capture checks this first: when SatDump finds no SDRplay receiver it
restarts SDRplay's service and looks again, and the log says what it found ("SDRplay receiver
found: RSP1A …") or what to do next. That restart needs a sudo rule the install adds, so run
`./install_and_upgrade.sh` once after updating. The same message also came when
`use_device_string` was true and the device ID was a serial number: SatDump numbers SDRplay
receivers 0, 1, … instead, so use `0` for the first one (a capture now falls back to the first
receiver and says so in the log).

1. **Is it seen?** The Live log's SDR card should show it as connected (since v1.31.2). Then:

   ```bash
   lsusb | grep -i 1df7                       # the receiver on USB (e.g. "1df7:3000 SDRplay RSP1a")
   systemctl status sdrplay --no-pager | head -5
   ls /usr/lib/*-linux-gnu/satdump/plugins/ | grep -i sdrplay
   satdump sdr_probe 2>&1 | grep -i -E "sdrplay|rsp"
   ```

   The probe should list it (e.g. `RSP1A 2103…`). If it doesn't, restart SDRplay's service; it can
   miss a receiver that was plugged in after it started: `sudo systemctl restart sdrplay` (or
   reboot). If that isn't enough, stop the service, unplug the receiver for a few seconds, plug it
   back in and start the service again (`sudo systemctl stop sdrplay`, replug,
   `sudo systemctl start sdrplay`): a receiver left in a bad state, for example while the service
   was failing to start, needs this (seen on an RSP1A, 21/11/2026). If the plugin is missing, run
   `./install_and_upgrade.sh` again.

2. **Did the pass record?** In the Live log, or with
   `grep -E "SNR|Viterbi" /var/log/raspberry-lrpt/output.log | tail`, a pass with a signal shows an
   SNR above about 2 dB and `Viterbi : SYNCED`. **SNR 0.0 dB and `NOSYNC` for the whole pass**
   means the receiver recorded but no satellite signal reached it.

3. **Does the receiver deliver samples?** A 10-second test on the Meteor frequency (no pass needed):

   ```bash
   cd /tmp && satdump record /tmp/rsp_test --source sdrplay --samplerate 2e6 --frequency 137.9e6 \
     --if_gain 40 --lna_gain 5 --baseband_format cs16 --timeout 10
   python3 -c "import numpy as n,glob; d=n.fromfile(glob.glob('/tmp/rsp_test*')[0],n.int16).astype(float); print('samples',len(d)//2,'rms',round(n.sqrt((d**2).mean()),1),'max',int(abs(d).max()))"
   ```

   About 20 million samples and an RMS well above 0 mean the receiver works; the problem is the
   antenna side (step 4). An RMS of 0 or few samples means it isn't streaming: go back to step 1.
   A `max` close to 32767 means something strong is overloading it: lower the gain, or try
   `--fm_notch` / `--dab_notch` in `sdr_extra_options` (the broadcast-band notch filters).

4. **The antenna side.** The usual causes, most common first:
   - **An LNA at the antenna that the RTL-SDR used to power.** The SDRplay must power it too: set
     the bias tee on (`meteor_m2_3_enable_bias_tee: true` and `meteor_m2_4_enable_bias_tee: true`,
     or answer "yes" in the setup questions) and run the install. Only some models have a bias tee
     (the RSP1A, RSP1B, RSP2, RSPduo and RSPdx do).
   - **The cable on the wrong socket** (RSP2, RSPduo and RSPdx have more than one antenna input;
     choose it with `--antenna_input`, see below).
   - **Gain.** The setting is SDRplay's IF gain, 20 to 59, where 59 is the most gain. 40 is a
     reasonable start; try 45 to 50 on a quiet site.

   Adding `--bias` to the test in step 3 powers an LNA for that test only.

## Extra SatDump options

`sdr_extra_options` in `config/settings.yml` is added to every capture's `satdump live` command,
for options the setup questions don't cover, for example:

| Receiver | Example | What it does |
|---|---|---|
| HackRF | `--amp` | turns on the 14 dB RF amplifier |
| SDRplay | `--lna_gain 20` | sets the LNA state (more = more gain) |
| SDRplay | `--antenna_input 2` | antenna B on an RSP2, tuner 2 on an RSPduo, antenna C on an RSPdx (`1` is antenna B there) |
| SDRplay | `--agc_mode 1` | automatic IF gain |

Run the install after changing it.
