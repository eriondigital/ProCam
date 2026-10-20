# ProCam

An original pro camera app for iPhone (SwiftUI + AVFoundation + Vision + Core Image, iOS 17+).

## What's in v2

### SteadyZoom (custom stabilisation)
When you zoom past 1.1×, the lens zooms only to zoom ÷ 1.35. The last 1.35× becomes a crop window that moves to cancel shake.
1. **Measure:** Vision image registration finds how far each frame moved (on a 320 px greyscale copy, every frame). The gyroscope gives roll.
2. **Smooth:** the raw camera path runs through One-Euro filters. These are adaptive low-pass filters that crush small, jittery hand shake but follow a deliberate pan without lag.
3. **Correct:** each frame is shifted and rotated by (raw path − smoothed path), then the centre window is cropped.
4. **Never show edges:** the correction is clamped to the margin, and the clamp is fed back into the filters.

The stabilised feed is drawn through an AVSampleBufferDisplayLayer, and the saved HEIF is cropped to match.

### Lock-on
While zoomed, **long-press a subject**. Vision object tracking then keeps it centred inside the stabiliser's margin, and brackets show the lock. Tap anywhere to release it.

### Night Stack
NIGHT mode works in five steps:
1. Brightens exposure by +0.7 EV.
2. Locks exposure, focus and white balance.
3. Shoots 8 fast frames.
4. Aligns them with Vision.
5. Averages them, which cuts noise by about 2.8×, then lightly sharpens.

### Smart shutter
At 3× and beyond (and in Night), the shutter waits up to 1.5 s for a calm moment in the gyro signal.

### More
- **Looks:** Natural, Vivid, Warm Film, Cool Matte, Mono, Noir. They show live in the viewfinder and are baked into HEIF photos.
- **Zebra stripes** on blown highlights, plus focus peaking and an RGB histogram.
- **Self-timer** (3 s / 10 s). Press the shutter again to cancel.
- **Hardware shutter:** volume buttons, and Camera Control on iPhone 16 (iOS 17.2+).
- **AE/AF lock:** long-press when not zoomed.
- **Manual controls:** ISO, shutter, focus, white balance and EV, plus an exposure meter in manual.
- **Capture formats:** HEIF, ProRAW and Bayer RAW (DNG) at up to 48 MP.
- **Lenses and level:** a lens switcher with pinch zoom up to 15× per lens, and a grid with a horizon level.

## Build it
You need a Mac with Xcode 15+ and a real iPhone (the Simulator has no camera).

```
brew install xcodegen
cd ProCam
xcodegen generate
open ProCam.xcodeproj
```
Pick your Team under Signing & Capabilities and run on your phone.

Without XcodeGen, follow these steps:
1. Create a new iOS App in Xcode (SwiftUI) named ProCam, and delete its template Swift files.
2. Drag in everything from the `ProCam/` folder.
3. Set the deployment target to iOS 17.
4. Add these to the Info tab:
   - `Privacy - Camera Usage Description`
   - `Privacy - Photo Library Additions Usage Description`
5. Lock orientation to Portrait.

## Files
| File | What it does |
|---|---|
| `CameraController.swift` | Session, lenses, manual controls, zoom pipeline, capture flows |
| `SteadyZoom.swift` | Stabilisation engine, One-Euro filter, lock-on tracking |
| `ViewfinderRenderer.swift` | Draws processed frames (stabilised / Looks) |
| `MotionHub.swift` | Shared gyro: roll for stabilisation, shake level, gravity |
| `PhotoProcessor.swift` | HEIF crop + Look, Night Stack merge |
| `Looks.swift` | Colour looks |
| `FrameAnalyzer.swift` | Histogram, focus peaking, zebras |
| `CameraScreen.swift` / `Components.swift` | UI |
| `CameraPreview.swift` | Preview, gestures, volume-button shutter |

## Notes
- SteadyZoom runs in HEIF and Night. RAW and ProRAW skip it so the DNG matches what you framed.
- Bayer RAW is straight off the sensor, with no noise reduction.
- The tuning knobs are `steadyMargin` in `CameraController` and the `OneEuroFilter` values in `SteadyZoomEngine`. A lower `minCutoff` gives a steadier but floatier frame.
