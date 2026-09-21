/* Test-only: vmem registration deliberately disables decoder devices. Restore
 * the device selector before playback so the pixel oracle exercises the actual
 * VideoToolbox module. Compile against the exact candidate's native headers.
 * This helper is never linked into the SwiftVLC library or consumer apps. */
#include <vlc_common.h>
#include <vlc_variables.h>

void swiftvlc_test_enable_videotoolbox(void *player)
{
    var_SetString((vlc_object_t *) player, "dec-dev", "any");
}
