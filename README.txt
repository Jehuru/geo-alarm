GeoAlarm coordinated feature upgrade
====================================

Included:
- lib/main.dart: feature-center entry point and configurable alarm sound duration/vibration notification setting
- lib/feature_center_screen.dart: favourite destinations, alarm sound preferences, location sharing, GPS/background diagnostics, journey history
- lib/journey_screen.dart: off-route warning, ETA estimate, and completed/ended journey recording
- pubspec.yaml: share_plus dependency for the native share sheet
- android/app/src/main/AndroidManifest.xml: vibration permission

IMPORTANT
---------
1. Back up your current project before replacing files.
2. Extract this ZIP into the ROOT of your existing C:\Projects\geo_alarm folder and allow it to overwrite matching files.
3. Open PowerShell and run:

   cd C:\Projects\geo_alarm
   flutter pub get
   dart format lib\main.dart lib\journey_screen.dart lib\feature_center_screen.dart
   flutter analyze

4. If analysis reports errors, do not run or publish the app yet; share the complete output.

Notes:
- Your original project ZIP did not include the assets directory. This patch does not remove or replace it.
- Background tracking already existed in the supplied project; this upgrade adds diagnostics but does not guarantee tracking when Android force-stops the app or restricts background execution.
- Off-route warnings and live ETA run while the Live Journey screen is open. ETA is an estimate based on recent average movement and straight-line remaining distance, not live traffic.
- Journey sharing uses Android/iOS share UI; you choose the recipient. Location sharing requires working GPS.
- Sound duration controls the in-app audio player. Android notification sound duration can still be controlled by Android's notification channel/OS.
