/* modlink: open the hostless MADERA-MODS PCM link (codec AIF2 -> Moto Mod I2S)
 * and keep it running without ever writing data (hostless link: no buffer).
 * usage: modlink [device=65] [channels=1] [rate=48000] */
#include <fcntl.h>
#include <limits.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>
#include <sound/asound.h>

static volatile sig_atomic_t stop;
static void on_sig(int s) { (void)s; stop = 1; }

static void mask_set(struct snd_pcm_hw_params *p, int n, unsigned bit) {
    struct snd_mask *m = &p->masks[n - SNDRV_PCM_HW_PARAM_FIRST_MASK];
    memset(m, 0, sizeof(*m));
    m->bits[bit >> 5] |= 1u << (bit & 31);
}
static void int_set(struct snd_pcm_hw_params *p, int n, unsigned v) {
    struct snd_interval *i = &p->intervals[n - SNDRV_PCM_HW_PARAM_FIRST_INTERVAL];
    i->min = i->max = v; i->integer = 1;
}
static void params_init(struct snd_pcm_hw_params *p) {
    memset(p, 0, sizeof(*p));
    for (int n = SNDRV_PCM_HW_PARAM_FIRST_MASK; n <= SNDRV_PCM_HW_PARAM_LAST_MASK; n++)
        memset(&p->masks[n - SNDRV_PCM_HW_PARAM_FIRST_MASK], 0xff, sizeof(struct snd_mask));
    for (int n = SNDRV_PCM_HW_PARAM_FIRST_INTERVAL; n <= SNDRV_PCM_HW_PARAM_LAST_INTERVAL; n++) {
        struct snd_interval *i = &p->intervals[n - SNDRV_PCM_HW_PARAM_FIRST_INTERVAL];
        i->min = 0; i->max = ~0u;
    }
    p->rmask = ~0u; p->info = ~0u;
}

int main(int argc, char **argv) {
    int dev = argc > 1 ? atoi(argv[1]) : 65;
    unsigned ch = argc > 2 ? atoi(argv[2]) : 1;
    unsigned rate = argc > 3 ? atoi(argv[3]) : 48000;
    char path[64];
    snprintf(path, sizeof(path), "/dev/snd/pcmC0D%dp", dev);

    int fd = open(path, O_RDWR);
    if (fd < 0) { perror("open"); return 1; }

    struct snd_pcm_hw_params hw;
    params_init(&hw);
    mask_set(&hw, SNDRV_PCM_HW_PARAM_ACCESS, SNDRV_PCM_ACCESS_RW_INTERLEAVED);
    mask_set(&hw, SNDRV_PCM_HW_PARAM_FORMAT, SNDRV_PCM_FORMAT_S16_LE);
    mask_set(&hw, SNDRV_PCM_HW_PARAM_SUBFORMAT, SNDRV_PCM_SUBFORMAT_STD);
    int_set(&hw, SNDRV_PCM_HW_PARAM_CHANNELS, ch);
    int_set(&hw, SNDRV_PCM_HW_PARAM_RATE, rate);
    int_set(&hw, SNDRV_PCM_HW_PARAM_PERIOD_SIZE, 1024);
    int_set(&hw, SNDRV_PCM_HW_PARAM_PERIODS, 4);
    if (ioctl(fd, SNDRV_PCM_IOCTL_HW_PARAMS, &hw)) { perror("hw_params"); return 1; }

    /* never stop on underrun: no data will ever be written */
    struct snd_pcm_sw_params sw;
    memset(&sw, 0, sizeof(sw));
    unsigned long buf = 4096;
    sw.boundary = buf;
    while (sw.boundary * 2 <= LONG_MAX - buf) sw.boundary *= 2;
    sw.tstamp_mode = SNDRV_PCM_TSTAMP_NONE;
    sw.period_step = 1;
    sw.avail_min = 1;
    sw.start_threshold = 1;
    sw.stop_threshold = sw.boundary;
    sw.silence_threshold = 0;
    sw.silence_size = 0;
    if (ioctl(fd, SNDRV_PCM_IOCTL_SW_PARAMS, &sw)) perror("sw_params (ignored)");

    if (ioctl(fd, SNDRV_PCM_IOCTL_PREPARE)) { perror("prepare"); return 1; }
    if (ioctl(fd, SNDRV_PCM_IOCTL_START)) { perror("start"); return 1; }
    printf("modlink: pcm %d started (%u ch, %u Hz)\n", dev, ch, rate);
    fflush(stdout);

    signal(SIGINT, on_sig);
    signal(SIGTERM, on_sig);
    while (!stop) pause();

    ioctl(fd, SNDRV_PCM_IOCTL_DROP);
    close(fd);
    printf("modlink: stopped\n");
    return 0;
}
