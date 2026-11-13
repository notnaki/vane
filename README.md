# Vane website

Source for [vane.so](https://vane.so/), kept on the `website` branch of
[notnaki/vane](https://github.com/notnaki/vane). The native app and technical
documentation stay on `main`.

The site is plain HTML, CSS, JavaScript and native app media. Serve this branch's
root with `python3 -m http.server 8661` to browse it locally.

Run `node tests/galaxy.test.cjs` and `python3 tests/site-links.py` before a website
change. Pull requests target `website`; website CI does not build the native app.

App capture, font and banner provenance is in [media/README.md](media/README.md).
Search and shared-link maintenance is documented in the application branch's
[website guide](https://github.com/notnaki/vane/blob/main/docs/WEBSITE.md).
