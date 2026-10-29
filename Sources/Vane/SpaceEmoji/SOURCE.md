# Space emoji catalog

Names, order, sequences and categories come from Unicode 16.0's
[emoji-test.txt](https://unicode.org/Public/emoji/16.0/emoji-test.txt), dated 2024-08-14.
Only fully-qualified entries are included. Smileys/Emotion and People/Body share
one picker category. Rendering uses macOS's emoji font; the app makes no catalog
network requests. The adjacent LICENSE.txt contains Unicode's permissive data license.

Source SHA-256: `24f0c534e86cf142e2496953e8f0e46a3e702392911eddcd29c6cced85139697`.

Regenerate from the repository root:

```sh
curl --fail --location https://unicode.org/Public/emoji/16.0/emoji-test.txt -o /tmp/vane-emoji-test-16.0.txt
python3 scripts/update-space-emoji.py /tmp/vane-emoji-test-16.0.txt Sources/Vane/SpaceEmoji/emoji.json
```
