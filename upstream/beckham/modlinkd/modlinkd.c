/* modlinkd: keep the hostless MADERA-MODS PCM link (codec AIF2 -> Moto Mod I2S)
 * open while the audio HAL routes playback to the mod.
 *
 * LineageOS' CAF audio HAL applies the "mod-speaker" mixer path (which sets
 * "Mods Enable Output Devices" != 0) but never opens PCM 65, which Motorola's
 * HAL did: without it the mod's I2S port is never activated and stays silent.
 *
 * The link is hostless: it must be started WITHOUT writing any data
 * (writing to it oopses the kernel in copy_from_user).
 * Only S16_LE / 1 channel / 48 kHz / 1024x4 periods is accepted by AIF2. */
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>
#include <sound/asound.h>
#include <android/log.h>

#define TAG "modlinkd"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, TAG, __VA_ARGS__)

#define CTL_PATH "/dev/snd/controlC0"
#define PCM_PATH "/dev/snd/pcmC0D65p"
#define CTL_NAME "Mods Enable Output Devices"
#define POLL_US 250000

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

static int link_open(void) {
    int fd = open(PCM_PATH, O_RDWR);
    if (fd < 0) { LOGE("open %s: %s", PCM_PATH, strerror(errno)); return -1; }

    struct snd_pcm_hw_params hw;
    params_init(&hw);
    mask_set(&hw, SNDRV_PCM_HW_PARAM_ACCESS, SNDRV_PCM_ACCESS_RW_INTERLEAVED);
    mask_set(&hw, SNDRV_PCM_HW_PARAM_FORMAT, SNDRV_PCM_FORMAT_S16_LE);
    mask_set(&hw, SNDRV_PCM_HW_PARAM_SUBFORMAT, SNDRV_PCM_SUBFORMAT_STD);
    int_set(&hw, SNDRV_PCM_HW_PARAM_CHANNELS, 1);
    int_set(&hw, SNDRV_PCM_HW_PARAM_RATE, 48000);
    int_set(&hw, SNDRV_PCM_HW_PARAM_PERIOD_SIZE, 1024);
    int_set(&hw, SNDRV_PCM_HW_PARAM_PERIODS, 4);
    if (ioctl(fd, SNDRV_PCM_IOCTL_HW_PARAMS, &hw)) {
        LOGE("hw_params: %s", strerror(errno)); close(fd); return -1;
    }

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
    if (ioctl(fd, SNDRV_PCM_IOCTL_SW_PARAMS, &sw)) LOGE("sw_params: %s (ignored)", strerror(errno));

    if (ioctl(fd, SNDRV_PCM_IOCTL_PREPARE) || ioctl(fd, SNDRV_PCM_IOCTL_START)) {
        LOGE("prepare/start: %s", strerror(errno)); close(fd); return -1;
    }
    return fd;
}

static void link_close(int fd) {
    ioctl(fd, SNDRV_PCM_IOCTL_DROP);
    close(fd);
}

/* returns control numid, or 0 if not found (gb_audio not loaded yet) */
static unsigned find_ctl(int ctl) {
    struct snd_ctl_elem_id id;
    memset(&id, 0, sizeof(id));
    id.iface = SNDRV_CTL_ELEM_IFACE_MIXER;
    strncpy((char *)id.name, CTL_NAME, sizeof(id.name) - 1);
    struct snd_ctl_elem_info info;
    memset(&info, 0, sizeof(info));
    info.id = id;
    if (ioctl(ctl, SNDRV_CTL_IOCTL_ELEM_INFO, &info)) return 0;
    return info.id.numid;
}

static long read_ctl(int ctl, unsigned numid) {
    struct snd_ctl_elem_value v;
    memset(&v, 0, sizeof(v));
    v.id.numid = numid;
    if (ioctl(ctl, SNDRV_CTL_IOCTL_ELEM_READ, &v)) return -1;
    return v.value.integer.value[0];
}

int main(void) {
    signal(SIGINT, on_sig);
    signal(SIGTERM, on_sig);

    int ctl = -1, link = -1;
    unsigned numid = 0;
    LOGI("started");

    while (!stop) {
        if (ctl < 0) ctl = open(CTL_PATH, O_RDONLY);
        if (ctl >= 0 && !numid) numid = find_ctl(ctl);

        long out = (ctl >= 0 && numid) ? read_ctl(ctl, numid) : -1;
        if (out < 0 && numid) {           /* card reset: look the control up again */
            close(ctl); ctl = -1; numid = 0;
        }

        if (out > 0 && link < 0) {
            link = link_open();
            LOGI("mod output devices=0x%lx -> link %s", out, link >= 0 ? "opened" : "FAILED");
            if (link < 0) usleep(1000000);    /* don't spam retries */
        } else if (out <= 0 && link >= 0) {
            link_close(link);
            link = -1;
            LOGI("mod output disabled -> link closed");
        }
        usleep(POLL_US);
    }

    if (link >= 0) link_close(link);
    if (ctl >= 0) close(ctl);
    LOGI("stopped");
    return 0;
}
