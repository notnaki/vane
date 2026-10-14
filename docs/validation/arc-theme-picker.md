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
The catalog has five pages of nine presets: Brand, Multicolour, Pastel, Drab, Greyscale.
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

## Multicolour presets and upper intensity range (2026-10-14)

All nine multicolour presets were selected in the installed Arc app and their
saved Display P3 palettes compared. Each uses the Brand page's corresponding
primary, with equal saturation/lightness and neighbours at +40° and −40°.
They use Arc's analogous harmony; the ordinary + arrangement remains the wider
complementary harmony. Removing and adding a dot on an analogous preset retains
its harmony. Keep that mode through saved neutral endpoints, which lose RGB hue.
Extended sRGB components outside 0...1 must be converted without clipping.

Arc stores two base colours and a transparent-to-third-colour vertical overlay.
The window, Library cards and preset swatches now share that arrangement. The
surface's overlay weight is animatable so a Space switch still reaches the exact
resting surface before its handoff.

For the same dark blue (#666789 fallback), maximum-intensity sidebar samples in
Display P3 were approximately Arc (91.7,92.4,119.6), former Vane (86.9,89.7,105.4),
and updated Vane (89.2,89.7,115.4), with identical window placement. Vane's upper
slider range now smoothly increases wash opacity to 0.90, with a small dark shade
correction. This is representative visual calibration, not an exact recreation
of Arc's compositor over every wallpaper/display. Existing settings through 0.8
retain their previous wash. Dot colours remain the saved, unshaded palette.

Native Vane QA confirmed gradient selection, dragging at ±40°, analogous minus/
plus, and opposing colours from + after a plain preset. The content card also
has a constant dark rim and soft outline shadow so its edge survives bright
Space colours without placing a tint over web content.
