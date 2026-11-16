# homr transformer protocol

`StaffDecoder.kt` and `PageSegmentation.kt` implement transformer decoding
and segmentation using ONNX Runtime on Android, based on homr 0.7.0 by Christian
Liebhardt and contributors, distributed under AGPL-3.0. It is an Android port
and differs from the upstream Python implementation. Upstream:
https://github.com/liebharc/homr

The upstream license is reproduced in `LICENSE`. Model weights are not tracked
in this repository. Standard builds omit weights; opt-in local test APKs can
include a separately supplied, hash-verified model bundle. Their separate
distribution terms must be established before redistribution. This notice does not resolve licensing of
the combined application or its release; that requires a distribution decision.
`android/app/src/main/assets/omr/vocabulary.json` is generated from homr's
vocabulary definitions by `scripts/export_mobile_vocabulary.py`.
