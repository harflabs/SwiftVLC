#include <vlc/vlc.h>
#include <stdio.h>
#include <unistd.h>
int main(int argc, char **argv) {
 if (argc != 3) return 2;
 const char *opts[] = {"--vout=dummy", "--aout=dummy", "--no-video-title-show", "--verbose=2"};
 libvlc_instance_t *vlc = libvlc_new(4, opts);
 if (!vlc) return 3;
 libvlc_media_t *media = libvlc_media_new_location(argv[1]);
 libvlc_media_add_option(media, argv[2]);
 libvlc_media_player_t *player = libvlc_media_player_new(vlc);
 libvlc_media_player_set_media(player, media);
 if (libvlc_media_player_play(player)) return 4;
 int decoded = 0;
 for (int i=0; i<150; i++) {
   libvlc_media_stats_t stats;
   if (libvlc_media_get_stats(media, &stats)) decoded = stats.i_decoded_video;
   if (decoded >= 10 || libvlc_media_player_get_state(player)==libvlc_Error) break;
   usleep(100000);
 }
 fprintf(stdout,"decoded_video=%d\n", decoded);
 libvlc_media_player_stop_async(player);
 for (int i=0; i<100 && libvlc_media_player_get_state(player)!=libvlc_Stopped; i++) usleep(100000);
 int stopped = libvlc_media_player_get_state(player)==libvlc_Stopped;
 libvlc_media_player_release(player); libvlc_media_release(media); libvlc_release(vlc);
 if (!stopped) return 5;
 return decoded>=10 ? 0 : 1;
}
