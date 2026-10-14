# Arc theme picker measurements

Observed on macOS 27, 2026-10-14, using the installed Arc app. Native pointer
sampling was used after the computer-use drag action failed to move the dots.
No Arc implementation code is included.

## Pad

The pad is a 340pt square. Hue runs clockwise from red on the right, through
yellow/green below, cyan on the left, and blue/purple above. The picker captures
the primary colour's **Display P3 HSL saturation** and its lightness interval
`max(0, L − 0.25)...min(1, L + 0.25)` when opened or when choosing a preset.
Radius maps linearly into that interval. The interval stays fixed throughout a
drag. At the exact centre, keep the incoming hue.

This is a stateful mapping: the centre is not universally black. Starting from
black gives a neutral 0...0.25 lightness range; starting from white gives
0.75...1. Reopening recalibrates the range around the saved colour. The dot's
visible centre stays inside the pad; pointer movement beyond that visual clamp
can still reach the range endpoint.

One large primary dot (44pt) and up to two small companions (26pt) are shown.
Adding the second gives the opposite hue; adding the third rebuilds the
companions at ±150 degrees. A preset replaces the gradient with one colour.
The catalog has four pages of nine colours: Brand, Pastel, Drab, Greyscale.
Several catalog colours are Display P3; clipping to hex sRGB is visibly lossy.

## Intensity

The measured 224pt track has fixed 8pt end insets. At intensity 0.8 the thumb
centre is 174.4pt from its left edge, independent of the thumb's growing size.
The thumb grows from approximately 12×48pt to 28×64pt over the range.
The whole wave changes amplitude with intensity (approximately 14pt maximum,
5.5 cycles). Past the thumb it continues with a dimmer stroke. At zero it is
flat throughout; it does not become flat only to the right of the thumb.

The primary dot keeps its colour while the window wash changes. In a fixed
wallpaper sample, a pale P3 colour's sidebar mean RGB changed from approximately
(123,121,122) at zero to (201,188,188) at one, with intermediate values following
the track. Intensity therefore changes the whole wash, including brightness;
it is not a saturation-only control.

## Verification

Regression tests cover calibration, hue orientation, clipped black/white
ranges, saturation preservation, growing-thumb travel, harmonic companions,
wide-gamut persistence, and invalidation by legacy hex edits. Visual comparison
is still required for rendering, which depends on the wallpaper and display.
