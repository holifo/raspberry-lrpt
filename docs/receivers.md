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

> SDRplay support was built and tested without an SDRplay receiver: the plugin builds and SatDump
> loads it, but the first real pass will be its first test. If it doesn't work, run
> `./scripts/tools/verification_tool/verification.sh quick`, check `sudo systemctl status sdrplay`
> and open an issue with the log.

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
