# ONNX Runtime JNI looks up Java classes and members by name. R8 must retain
# these even when the Java call graph alone does not reference them.
# https://onnxruntime.ai/docs/build/android.html#note-proguard-rules-for-r8-minimization-android-app-builds-to-work
-keep class ai.onnxruntime.** { *; }
