# Shared libraries the Android platform itself provides.
#
# Sourced by scripts that walk DT_NEEDED entries and need to tell "this module
# depends on something nobody shipped" apart from "this module depends on
# something every phone already has". One list, so the two cannot drift.
#
# Keep it to things that really are on the device.

PLATFORM_LIBS="
libc.so libm.so libdl.so liblog.so libz.so libstdc++.so
libEGL.so libGLESv1_CM.so libGLESv2.so libGLESv3.so
libOpenSLES.so libOpenMAXAL.so libandroid.so libjnigraphics.so
libnativewindow.so libvulkan.so libaaudio.so libamidi.so
libcamera2ndk.so libmediandk.so libneuralnetworks.so libsync.so
libbinder_ndk.so libcutils.so libutils.so libui.so libgui.so
libhwui.so libskia.so libft2.so libharfbuzz_ng.so libpng.so
libcrypto.so libssl.so libcompiler_rt.so libm_hard.so
"

# Collapse whitespace: the list is matched with " name ", so a name sitting at
# the end of a line -- followed by a newline rather than a space -- would not
# match and would be reported as missing.
PLATFORM_LIBS=" $(printf '%s' "$PLATFORM_LIBS" | tr '\n\t' '  ') "
