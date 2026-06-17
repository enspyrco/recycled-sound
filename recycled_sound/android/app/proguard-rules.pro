# R8/ProGuard rules for the release build.
#
# ML Kit text recognition and TensorFlow Lite reference optional classes that
# this app does not bundle (we use Latin-script OCR + the CPU TFLite delegate
# only). R8 full mode errors on these "missing class" references unless we tell
# it not to warn — and we keep the classes we DO call reflectively.

# --- ML Kit text recognition ---
# We bundle the Latin recognizer only; the CJK/Devanagari language models are
# optional and intentionally absent.
-dontwarn com.google.mlkit.vision.text.chinese.**
-dontwarn com.google.mlkit.vision.text.devanagari.**
-dontwarn com.google.mlkit.vision.text.japanese.**
-dontwarn com.google.mlkit.vision.text.korean.**
-keep class com.google.mlkit.** { *; }
-keep class com.google.android.gms.internal.mlkit_vision_text_common.** { *; }

# --- TensorFlow Lite ---
# The GPU delegate is optional; we run on the CPU delegate.
-dontwarn org.tensorflow.lite.gpu.**
-keep class org.tensorflow.lite.** { *; }
-keep class org.tensorflow.** { *; }
