# Web panel screenshots

Sample screenshots of every view, with sample passes and real METEOR-M2 imagery decoded by SatDump
from the verification tool's test recording. They are made by `scripts/dev/make_screenshots.sh`
(dev machine), so they can be refreshed after a change to the web panel.

## Passes

The station bar, the next-pass card (here while a pass is being recorded) and today's passes.
Tapping a pass opens it on the Satellites tab. Dark and light mode follow the device unless chosen with the button.

![Passes, dark](assets/screenshots/passes-dark.jpg)

![Passes, light](assets/screenshots/passes-light.jpg)

Today is open; the other days are folded to one line with their passes per satellite and the best
elevation. Times are local, as the note above the list says.

![Passes by day](assets/screenshots/passes-days.jpg)

The language menu in the top bar (English, German, French, Italian, Spanish, Greek, Chinese, Hindi, Arabic):

![Language menu](assets/screenshots/language-menu.jpg)

In Greek:

![Passes in Greek](assets/screenshots/passes-greek.jpg)

On a phone:

<img src="assets/screenshots/passes-phone.jpg" alt="Passes on a phone" width="390">

While a pass is being recorded, a live decode panel appears under the next-pass card: SatDump's
spectrum and waterfall, the SNR, the Viterbi and frame-sync locks, the BER, the Reed-Solomon
corrections and the frequency offset, updated every second. The constellation is estimated from
the SNR, because SatDump 1.2.3 does not share its real one. (This picture was taken with a test
signal, which never locks.)

![Live decode panel](assets/screenshots/live-decode.jpg)

## Satellites

The live ground-track map fills the window. Beside it are the selected satellite's details
(position, look angles from the station, next pass, orbit) and the coming passes. Tapping a pass
draws its track with the AOS and LOS times and selects its satellite.

![Satellites tab](assets/screenshots/satellites.jpg)

The map in full screen:

![Map in full screen](assets/screenshots/map-fullscreen.jpg)

On a phone the details and the list sit under the map:

<img src="assets/screenshots/satellites-phone.jpg" alt="Satellites tab on a phone" width="390">

## Meteor-M

The Sat info tab: the Meteor-M series (the two satellites this station receives, a timeline of every
launch and plan, the LRPT signal and the instruments) and, further down, the ISS as an extra (its
orbit, amateur radio frequencies and the year's ARISS SSTV events), with the sources the facts come
from.

![Sat info tab](assets/screenshots/meteor.jpg)

## ISS APRS

Between ARISS SSTV events the ISS extra records the ISS's APRS digipeater (145.825 MHz). Each pass
gets a page with a map of the stations heard and the ISS's track, the list of stations and the
packets as received; while a pass is recorded, the stations also show up live on the Satellites map.

![An ISS APRS pass](assets/screenshots/iss-aprs.jpg)

## Captures

Captures grouped by day:

![Captures](assets/screenshots/captures.jpg)

One capture: the pass details, a download link for its recording, every image SatDump made, the
spectrogram, the elevation/azimuth graph and the sky track.

![One capture](assets/screenshots/capture.jpg)

Clicking an image opens the viewer (zoom, pan, previous/next):

![Image viewer](assets/screenshots/image-viewer.jpg)

## Daily map

Each day's day and night maps and its time-lapse, newest day open, older days folded with a
summary and thumbnails.

![Daily map](assets/screenshots/daily.jpg)

## Live log

System dashboard and the station log at `/log` (public, no password). The sample machine has no RTL-SDR and
no temperature sensor.

![Live log](assets/screenshots/live-log.jpg)

![Live log, light](assets/screenshots/live-log-light.jpg)

## Admin

At `/admin/passes` and `/admin/captures`, behind the admin login.

![Admin, passes](assets/screenshots/admin-passes.jpg)

![Admin, captures](assets/screenshots/admin-captures.jpg)
