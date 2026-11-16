# LibRaw 0.22.2

Source: https://github.com/LibRaw/LibRaw/tree/0.22.2

Unmodified upstream source is vendored in `vendor/LibRaw-0.22.2` and distributed
with the application under CDDL 1.0. Copyright notices and both upstream license
texts are retained there. The application-specific bridge is `raw_converter.cpp`.

The macOS helper uses Apple's ImageIO encoders and system zlib. The Windows
helper uses Windows Imaging Component. No user-installed RAW tools are required.
Optional LibRaw SDKs (Adobe DNG SDK, RawSpeed, LCMS, external JPEG libraries)
are not enabled; RAW variants requiring those optional decoders may be rejected.
